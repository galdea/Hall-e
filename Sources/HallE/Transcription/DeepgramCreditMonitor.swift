import Foundation
import UserNotifications

/// Tells Gabriel when Deepgram transcription is about to stop, or has stopped,
/// for a money reason. Two independent things can halt it and both are covered:
///
/// - the Deepgram account running out of credit (the free grant being used up),
///   which the API reports as HTTP 402 or an insufficient-credits error code; and
/// - Hall-E's own monthly spend guard being reached, which stops uploads locally
///   before any request is made.
///
/// Balance cannot be polled with a transcription-scoped key — Deepgram answers
/// `INSUFFICIENT_PERMISSIONS` without `billing:read`. The proactive check is
/// therefore best-effort and silently inert until a key with that scope exists;
/// the reactive path is what actually guarantees notice.
enum DeepgramCreditReason: String {
    case creditExhausted = "credit-exhausted"
    case lowBalance = "low-balance"
    case monthlyGuardReached = "monthly-guard-reached"
    /// The primary account ran dry and the spare took over. Transcription still
    /// works, so this is a warning, not a failure — but it must not be silent,
    /// because the spare is the last line before transcription stops entirely.
    case switchedToFallback = "switched-to-fallback"
}

@MainActor enum DeepgramCreditMonitor {
    /// Warn once the remaining provider balance drops below this, when readable.
    static let lowBalanceThresholdUSD = 5.0
    /// One alert per reason per day, so a batch of failures is not a batch of alerts.
    static let renotifyInterval: TimeInterval = 24 * 60 * 60

    private static let defaults = UserDefaults.standard
    private static func key(_ reason: DeepgramCreditReason) -> String {
        "deepgramCreditNotified.\(reason.rawValue)"
    }

    static func shouldNotify(_ reason: DeepgramCreditReason, now: Date = Date()) -> Bool {
        guard let last = defaults.object(forKey: key(reason)) as? Date else { return true }
        return now.timeIntervalSince(last) >= renotifyInterval
    }

    /// Clears the throttle so a recovered account alerts again if it later fails.
    static func resetThrottle() {
        for reason in [DeepgramCreditReason.creditExhausted, .lowBalance, .monthlyGuardReached, .switchedToFallback] {
            defaults.removeObject(forKey: key(reason))
        }
    }

    enum NotifyOutcome: Equatable {
        case posted
        case throttled
        case notAuthorized(String)
        case failed(String)
    }

    @discardableResult
    static func notify(_ reason: DeepgramCreditReason, detail: String? = nil,
                       now: Date = Date()) async -> NotifyOutcome {
        guard shouldNotify(reason, now: now) else { return .throttled }
        defaults.set(now, forKey: key(reason))

        let content = UNMutableNotificationContent()
        switch reason {
        case .creditExhausted:
            content.title = "Deepgram credit has run out"
            content.body = detail ?? "Every configured Deepgram account is out of credit, so meeting transcription has stopped. Recordings and audio are kept, and queued meetings will transcribe once credit is restored."
        case .lowBalance:
            content.title = "Deepgram credit is running low"
            content.body = detail ?? "Top up before it stops transcribing meetings."
        case .monthlyGuardReached:
            content.title = "Hall-e paused Deepgram uploads"
            content.body = detail ?? "The monthly spend guard was reached. Raise it in Settings → Transcription to continue."
        case .switchedToFallback:
            content.title = "Deepgram switched to the fallback account"
            content.body = detail ?? "The primary Deepgram account is out of credit. Transcription continues on the fallback key — top the primary up, or add another spare, before this one runs out too."
        }
        content.sound = .default

        let status = await NotificationScheduler.shared.requestAuthorizationIfNeeded()
        guard status == .authorized || status == .provisional else {
            Log.notify.error("deepgram credit alert suppressed: notifications not authorized")
            return .notAuthorized("authorization status \(status.rawValue)")
        }
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "halle-deepgram-\(reason.rawValue)-\(UUID().uuidString)",
                content: content, trigger: nil))
            Log.notify.info("deepgram credit alert posted: \(reason.rawValue, privacy: .public)")
            return .posted
        } catch {
            Log.notify.error("deepgram credit alert failed: \(error, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// Maps a provider failure onto an alert. Only money-related failures notify;
    /// a transient 500 or a bad request must not cry wolf about credit.
    /// Called after a successful transcription so a silent failover still tells
    /// Gabriel the primary account is finished.
    static func noteCredentialUsed(_ credential: String?) async {
        guard credential == "fallback" else { return }
        await notify(.switchedToFallback)
    }

    static func handle(_ error: DeepgramError) async {
        switch error {
        case .creditExhausted(let message):
            await notify(.creditExhausted, detail: message)
        case .spendLimitExceeded(let projected, let limit):
            await notify(.monthlyGuardReached,
                         detail: "Projected $\(String(format: "%.2f", projected)) would pass the $\(String(format: "%.2f", limit)) monthly guard. Raise it in Settings → Transcription to continue.")
        default:
            break
        }
    }

    // MARK: - Proactive balance check

    /// Reads the remaining balance when the key is allowed to. Returns `nil` when
    /// the scope is missing, the network fails, or the account has no balance
    /// record — none of which are evidence that credit is gone, so none notify.
    static func remainingBalanceUSD(session: URLSession = .shared) async -> Double? {
        guard let key = KeychainStore.get(account: KeychainStore.deepgramTranscriptionAccount),
              !key.isEmpty else { return nil }

        func get(_ url: URL) async -> [String: Any]? {
            var request = URLRequest(url: url)
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json
        }

        guard let projects = await get(URL(string: "https://api.deepgram.com/v1/projects")!),
              let list = projects["projects"] as? [[String: Any]],
              let projectID = list.first?["project_id"] as? String,
              let balances = await get(URL(string: "https://api.deepgram.com/v1/projects/\(projectID)/balances")!),
              let entries = balances["balances"] as? [[String: Any]] else { return nil }

        let total = entries.compactMap { $0["amount"] as? Double }.reduce(0, +)
        return total
    }

    /// Best-effort check for a low balance. Safe to call on launch and on a timer.
    static func checkBalance() async {
        guard AppPreferences.allowCloudAudioTranscription,
              KeychainStore.exists(account: KeychainStore.deepgramTranscriptionAccount) else { return }
        guard let remaining = await remainingBalanceUSD() else {
            Log.notify.debug("deepgram balance not readable (billing:read scope absent) — relying on request failures")
            return
        }
        Log.notify.info("deepgram balance remaining: \(remaining, privacy: .public)")
        if remaining <= 0 {
            await notify(.creditExhausted,
                         detail: "The Deepgram account has no credit left. Meeting transcription has stopped; audio is still recorded and will transcribe once credit is restored.")
        } else if remaining < lowBalanceThresholdUSD {
            await notify(.lowBalance,
                         detail: "About $\(String(format: "%.2f", remaining)) of Deepgram credit remains. Top up before it stops transcribing meetings.")
        }
    }
}
