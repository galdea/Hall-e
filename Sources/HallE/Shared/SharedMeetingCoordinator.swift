import AppKit
import CryptoKit
import Foundation
import Observation

struct SharedDeviceRecord: Codable, Identifiable {
    let id: String
    let name: String
    let revokedAtMs: Double?
}

struct SharedMeetingRecord: Identifiable {
    let id: String
    let title: String
    let projectName: String?
    let meetingURL: String?
    let startAt: Date
    let endAt: Date?
    let revision: Int
}

struct SharedSegmentRecord: Codable, Identifiable {
    let id: String
    let sessionId: String
    let deviceId: String
    let startedAtMs: Double
    let endedAtMs: Double?
    let status: String
}

struct SharedRecordingLease: Codable {
    let sessionId: String
    let deviceId: String
    let leaseId: String
    let generation: Int
    let generationToken: String?
    let expiresAtMs: Double
    let handoffRequestedDeviceId: String?

    var proof: [String: Any] {
        ["leaseId": leaseId, "generation": generation, "generationToken": generationToken ?? ""]
    }
}

enum SharedCredentialsLoadState: Equatable {
    case loading
    case unpaired
    case paired
    case failed(String)

    var permitsUnpairedLocalCapture: Bool { self == .unpaired }
}

/// Wire data is interoperable with Android: AES-GCM nonce(12) + ciphertext + tag(16).
enum SharedMeetingCrypto {
    static func encrypt(_ data: Data, key: Data, sessionID: String) throws -> String {
        guard key.count == 32 else { throw SharedMeetingError.invalidInvitation }
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: key),
                                   authenticating: Data("session:\(sessionID)".utf8))
        guard let combined = box.combined else { throw SharedMeetingError.invalidInvitation }
        return combined.base64EncodedString()
    }
    static func decrypt(_ value: String, key: Data, sessionID: String) throws -> Data {
        guard key.count == 32, let data = Data(base64Encoded: value), data.count <= 8192 else {
            throw SharedMeetingError.invalidInvitation
        }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key),
                                authenticating: Data("session:\(sessionID)".utf8))
    }
    static func urlEncode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func urlDecode(_ value: String) -> Data? {
        guard value.count <= 6000 else { return nil }
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}

/// A late network response can never revive capture after its conservative local deadline.
struct SharedLeaseDeadline {
    private(set) var expiresUptime: TimeInterval = 0
    mutating func grant(requestStarted: TimeInterval, receivedAt: TimeInterval) -> Bool {
        let deadline = requestStarted + 15
        guard receivedAt < deadline else { return false }
        expiresUptime = deadline
        return true
    }
    func isValid(at uptime: TimeInterval) -> Bool { uptime < expiresUptime }
    mutating func invalidate() { expiresUptime = 0 }
}

enum SharedMeetingError: LocalizedError {
    case invalidInvitation, unavailable, server(Int, String), inactive, busy, lostLease
    case credentialsLoading, credentialsUnavailable, invalidStoredCredentials
    var errorDescription: String? {
        switch self {
        case .invalidInvitation: return "This pairing invitation is invalid or belongs to another service."
        case .unavailable: return "Shared meetings could not connect. Check your internet connection."
        case .server(_, let code):
            switch code {
            case "lease_held": return "Another device is recording. Open Shared meetings and choose Record here to switch."
            case "revision_conflict": return "This meeting changed on another device. Refresh and try again."
            case "invite_invalid", "invite_expired": return "The invitation expired or has already been used. Create a new one."
            case "unauthorized", "device_revoked", "token_expired": return "This device is no longer linked. Connect it again."
            default: return "The shared meeting service could not complete this action (\(code))."
            }
        case .inactive: return "Return to Hall-e and choose Record here to start recording on this Mac."
        case .busy: return "Another recording is starting or stopping. Wait for it to finish."
        case .lostLease: return "Recording stopped because this Mac could not renew its shared-session permission."
        case .credentialsLoading: return "Hall-e is still checking this Mac's saved shared-device link. Retry after that check finishes."
        case .credentialsUnavailable: return "Hall-e could not verify this Mac's saved shared-device link. Retry the Keychain check before pairing or recording."
        case .invalidStoredCredentials: return "The saved shared-device link is unreadable. It was kept unchanged; retry the Keychain check or contact support."
        }
    }
}

private struct SharedMeetingPayload: Codable {
    var v = 1
    var title: String
    var projectName: String?
    var meetingUrl: String?
    var startAtMs: Double
    var endAtMs: Double?
}

private struct SharedStoredSession: Codable {
    let id: String
    let encryptedPayload: String
    let revision: Int
}

private struct SharedWorkspaceState: Codable {
    let ownerDeviceId: String
    let devices: [SharedDeviceRecord]
    let sessions: [SharedStoredSession]
    let activeLease: SharedRecordingLease?
    let segments: [SharedSegmentRecord]
}

private struct SharedCredentials: Codable {
    let endpoint: String
    let workspaceId: String
    let deviceId: String
    let deviceToken: String
    let key: String
    var owner: Bool
}

private final class SharedNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor @Observable
final class SharedMeetingCoordinator {
    static let shared = SharedMeetingCoordinator()
    nonisolated static let endpoint = "https://halle-shared-session-coordinator.gabriel-aldea.workers.dev"
    private static let account = "shared-meetings-v1"
    private var credentials: SharedCredentials?
    private var ownedLease: SharedRecordingLease?
    private var leaseDeadline = SharedLeaseDeadline()
    private var heartbeat: Task<Void, Never>?
    private var watchdog: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var epoch = UUID()
    private var recordingStartMs: Double?
    private var recordingSegmentID: String?
    private var segmentStartTask: Task<Void, Never>?
    private var isFinishingCapture = false
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let session: URLSession
    private let credentialReader: () async throws -> String?
    private var credentialLoadGeneration = UUID()
    private var credentialLoadTask: Task<Void, Never>?

    private(set) var devices: [SharedDeviceRecord] = []
    private(set) var meetings: [SharedMeetingRecord] = []
    private(set) var segments: [SharedSegmentRecord] = []
    private(set) var activeLease: SharedRecordingLease?
    private(set) var invitationURL: String?
    private(set) var isBusy = false
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private(set) var credentialsLoadState: SharedCredentialsLoadState = .loading
    private var actionErrorMessage: String?
    private var refreshErrorMessage: String?
    var isPaired: Bool { credentialsLoadState == .paired && credentials != nil }
    var deviceID: String? { credentials?.deviceId }
    var isOwner: Bool { credentials?.owner == true }
    var isRecordingHere: Bool { ownedLease != nil && RecordingService.shared.isRecording }
    var hasValidRecordingLease: Bool { ownedLease != nil && leaseDeadline.isValid(at: ProcessInfo.processInfo.systemUptime) }

    init(credentialReader: @escaping () async throws -> String? = {
        try await KeychainStore.getAsync(account: "shared-meetings-v1")
    }) {
        self.credentialReader = credentialReader
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: SharedNoRedirect(), delegateQueue: nil)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loseLease("This Mac is sleeping. The shared recording was stopped.") }
        }
        credentialLoadTask = Task { [weak self] in await self?.loadStoredCredentials() }
    }

    func retryCredentialLoad() async {
        guard credentialsLoadState != .loading else { return }
        beginAction()
        credentialLoadTask = Task { [weak self] in await self?.loadStoredCredentials() }
        await credentialLoadTask?.value
    }

    private var credentialLoadFailureMessage: String {
        switch credentialsLoadState {
        case .loading: return SharedMeetingError.credentialsLoading.localizedDescription
        case .failed(let detail): return "Could not read the saved shared-device link: \(detail)"
        case .unpaired, .paired: return SharedMeetingError.credentialsUnavailable.localizedDescription
        }
    }

    private func loadStoredCredentials() async {
        let generation = UUID()
        credentialLoadGeneration = generation
        credentialsLoadState = .loading
        do {
            let raw = try await credentialReader()
            guard credentialLoadGeneration == generation else { return }
            guard let raw else {
                credentials = nil
                credentialsLoadState = .unpaired
                return
            }
            guard let data = raw.data(using: .utf8),
                  let stored = try? decoder.decode(SharedCredentials.self, from: data),
                  stored.endpoint == Self.endpoint,
                  stored.workspaceId.isEmpty == false, stored.deviceId.isEmpty == false,
                  stored.deviceToken.isEmpty == false,
                  SharedMeetingCrypto.urlDecode(stored.key)?.count == 32 else {
                throw SharedMeetingError.invalidStoredCredentials
            }
            credentials = stored
            credentialsLoadState = .paired
        } catch {
            guard credentialLoadGeneration == generation else { return }
            credentials = nil
            credentialsLoadState = .failed(error.localizedDescription)
        }
    }

    func refresh(clearErrors: Bool = false) async {
        guard let config = credentials else { return }
        let generation = epoch
        if clearErrors {
            actionErrorMessage = nil
            refreshErrorMessage = nil
            publishError()
        }
        do {
            let data = try await request("/state", config: config)
            let state = try decoder.decode(SharedWorkspaceState.self, from: data)
            guard epoch == generation else { return }
            apply(state, key: try keyData(config))
            refreshErrorMessage = nil
            publishError()
        } catch {
            if epoch == generation {
                refreshErrorMessage = error.localizedDescription
                publishError()
            }
        }
    }

    func createInvitation() async {
        guard !isBusy, !RecordingService.shared.isRecording else { return }
        beginAction()
        guard credentialsLoadState == .unpaired || (credentialsLoadState == .paired && credentials != nil) else {
            setActionError(credentialLoadFailureMessage)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let invite: [String: Any]
            if let config = credentials {
                invite = try json(await request("/invites", method: "POST", body: [:], config: config))
            } else {
                let response = try json(await request("/v1/workspaces", method: "POST",
                                                      body: ["deviceName": "Hall-e on Mac"], config: nil))
                let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                let config = SharedCredentials(endpoint: Self.endpoint,
                    workspaceId: try string(response, "workspaceId"), deviceId: try string(response, "deviceId"),
                    deviceToken: try string(response, "deviceToken"), key: SharedMeetingCrypto.urlEncode(key), owner: true)
                try await save(config)
                invite = response
            }
            guard let config = credentials else { throw SharedMeetingError.unavailable }
            let value: [String: Any] = ["v": 1, "endpoint": config.endpoint, "workspaceId": config.workspaceId,
                "inviteToken": try string(invite, "inviteToken"), "key": config.key]
            let code = SharedMeetingCrypto.urlEncode(try JSONSerialization.data(withJSONObject: value))
            invitationURL = "https://hall-e.pages.dev/pair#\(code)"
            statusMessage = "Scan or paste this invitation on your phone. It expires in 10 minutes and works once."
            await refresh()
        } catch { setActionError(error.localizedDescription) }
    }

    func joinInvitation(_ raw: String) async {
        guard !isBusy, credentialsLoadState == .unpaired, !RecordingService.shared.isRecording else { return }
        isBusy = true; beginAction()
        defer { isBusy = false }
        do {
            let invitation = try Self.parseInvitation(raw)
            let temporary = SharedCredentials(endpoint: Self.endpoint,
                workspaceId: try string(invitation, "workspaceId"), deviceId: "", deviceToken: "",
                key: try string(invitation, "key"), owner: false)
            let result = try json(await request("/join", method: "POST",
                body: ["inviteToken": try string(invitation, "inviteToken"), "deviceName": "Hall-e on Mac"], config: temporary, authenticated: false))
            let config = SharedCredentials(endpoint: Self.endpoint, workspaceId: temporary.workspaceId,
                deviceId: try string(result, "deviceId"), deviceToken: try string(result, "deviceToken"), key: temporary.key, owner: false)
            try await save(config)
            statusMessage = "Devices linked. Shared meeting details are encrypted; audio stays on the device that records it."
            await refresh()
        } catch { setActionError(error.localizedDescription) }
    }

    nonisolated static func parseInvitation(_ raw: String) throws -> [String: Any] {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.count <= 6000 else { throw SharedMeetingError.invalidInvitation }
        var encoded = input
        if let url = URLComponents(string: input), url.scheme != nil {
            if url.scheme == "https", url.host == "hall-e.pages.dev", url.path == "/pair",
               url.user == nil, url.password == nil, url.port == nil, url.query == nil {
                encoded = url.fragment ?? ""
            } else if url.scheme == "halle", url.host == "pair", url.path.isEmpty,
                      url.user == nil, url.password == nil, url.port == nil, url.fragment == nil {
                encoded = url.queryItems?.first(where: { $0.name == "payload" })?.value ?? ""
            } else { throw SharedMeetingError.invalidInvitation }
        }
        guard let bytes = SharedMeetingCrypto.urlDecode(encoded),
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["v"] as? Int == 1, object["endpoint"] as? String == endpoint,
              let workspace = object["workspaceId"] as? String, UUID(uuidString: workspace) != nil,
              let invitation = object["inviteToken"] as? String, invitation.count >= 32, invitation.count <= 128,
              let key = object["key"] as? String, SharedMeetingCrypto.urlDecode(key)?.count == 32 else {
            throw SharedMeetingError.invalidInvitation
        }
        return object
    }

    func disconnect() async {
        guard let config = credentials, !isBusy, ownedLease == nil else { return }
        isBusy = true; beginAction(); defer { isBusy = false }
        do {
            _ = try await request("/leave", method: "POST", body: [:], config: config)
            guard await KeychainStore.deleteAsync(account: Self.account) else { throw SharedMeetingError.unavailable }
            epoch = UUID(); credentials = nil; invitationURL = nil
            credentialsLoadState = .unpaired
            devices = []; meetings = []; segments = []; activeLease = nil
            statusMessage = "This device is disconnected. Local recordings are still available."
            setActionError(nil)
        } catch { setActionError(error.localizedDescription) }
    }

    func revokeDevice(_ id: String) async {
        guard let config = credentials, isOwner, id != config.deviceId, !isBusy else { return }
        isBusy = true; beginAction(); defer { isBusy = false }
        do {
            _ = try await request("/devices/\(id)", method: "DELETE", config: config)
            await refresh()
        } catch { setActionError(error.localizedDescription) }
    }

    func createMeeting(title: String, projectName: String?, meetingURL: String? = nil, recordAfterCreation: Bool = false) async {
        guard !isBusy, credentials != nil else { return }
        isBusy = true; beginAction()
        var created: SharedMeetingRecord?
        do {
            created = try await createSession(title: title, project: projectName, meetingURL: meetingURL, start: Date(), end: nil)
            await refresh()
        } catch { setActionError(error.localizedDescription) }
        isBusy = false
        if recordAfterCreation, let created { await recordHere(created) }
    }

    func updateProject(_ meeting: SharedMeetingRecord, projectName: String?) async {
        guard let config = credentials, !isBusy else { return }
        isBusy = true; beginAction(); defer { isBusy = false }
        do {
            var payload = payload(meeting)
            payload.projectName = clean(projectName, limit: 80)
            let encrypted = try SharedMeetingCrypto.encrypt(encoder.encode(payload), key: keyData(config), sessionID: meeting.id)
            _ = try await request("/sessions/\(meeting.id)", method: "PATCH",
                                  body: ["encryptedPayload": encrypted, "expectedRevision": meeting.revision], config: config)
            await refresh()
        } catch { setActionError(error.localizedDescription) }
    }

    func recordHere(_ meeting: SharedMeetingRecord, takeOver: Bool = false) async {
        guard isPaired, !isBusy, ownedLease == nil, !RecordingService.shared.isRecording else { return }
        let alert = NSAlert()
        alert.messageText = takeOver ? "Move recording to this Mac?" : "Record on this Mac?"
        alert.informativeText = "Tell everyone before recording. Hall-e saves this microphone recording on this Mac. If another device is recording, it must stop before this Mac starts."
        alert.addButton(withTitle: takeOver ? "Move here and record" : "Record here")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isBusy = true; beginAction()
        defer { isBusy = false }
        do {
            guard await RecordingService.shared.requestMicAccess() else { throw SharedMeetingError.server(403, "microphone_denied") }
            guard let config = credentials else { throw SharedMeetingError.unavailable }
            if takeOver {
                _ = try await request("/lease/handoff", method: "POST", body: ["requestedDeviceId": config.deviceId], config: config)
                statusMessage = "Waiting for the other device to stop…"
            }
            let stopAt = ProcessInfo.processInfo.systemUptime + 26
            while true {
                guard NSApp.isActive else { throw SharedMeetingError.inactive }
                do { try await claim(meeting.id); break }
                catch SharedMeetingError.server(409, "lease_held") where takeOver && ProcessInfo.processInfo.systemUptime < stopAt {
                    try await Task.sleep(for: .seconds(1))
                }
            }
            guard NSApp.isActive, hasValidRecordingLease else { throw SharedMeetingError.inactive }
            let event = event(meeting)
            await RecordingService.shared.start(for: event, notePath: nil, sourceKind: .manual,
                sharedSessionID: meeting.id) { session in
                Task { await RecordingCoordinator.transcribeAndMerge(session: session, event: event) }
            }
            if !RecordingService.shared.isRecording { await captureFailed(); throw SharedMeetingError.busy }
            statusMessage = "Recording on this Mac. Audio stays here; the linked devices can see the recording status."
        } catch { await captureFailed(); setActionError(error.localizedDescription) }
    }

    /// Called by the native recording service before every capture when devices are linked.
    /// This authorizes ownership only; it never starts a recorder or grants microphone access.
    func prepareLocalCapture(event: UnifiedEvent, requestedSessionID: String?) async throws -> String? {
        if credentialsLoadState == .loading { await credentialLoadTask?.value }
        if let requestedSessionID {
            guard credentialsLoadState == .paired, credentials != nil,
                  ownedLease?.sessionId == requestedSessionID, hasValidRecordingLease else {
                throw SharedMeetingError.lostLease
            }
            return requestedSessionID
        }
        if credentialsLoadState.permitsUnpairedLocalCapture, credentials == nil { return nil }
        guard credentialsLoadState == .paired, credentials != nil else {
            if case .loading = credentialsLoadState { throw SharedMeetingError.credentialsLoading }
            throw SharedMeetingError.credentialsUnavailable
        }
        guard !isBusy, ownedLease == nil else { throw SharedMeetingError.busy }
        isBusy = true
        defer { isBusy = false }
        let meeting = try await createSession(title: event.title,
                                              project: AliasStore.shared.projectName(for: event.projectId) ?? event.projectId,
                                              meetingURL: event.meetingURL, start: event.startTs, end: event.endTs)
        try await claim(meeting.id)
        return meeting.id
    }

    func captureStarted(_ recording: RecordingSession) {
        guard let lease = ownedLease, recording.sharedSessionID == lease.sessionId else { return }
        recordingSegmentID = recording.id.uuidString.lowercased()
        recordingStartMs = ((recording.micStartedAt ?? recording.startedAt).timeIntervalSince1970 * 1000).rounded()
        segmentStartTask = Task { await sendSegment(recording: recording, terminal: false) }
    }

    func captureFinished(_ recording: RecordingSession?) async {
        guard let lease = ownedLease, !isFinishingCapture else { return }
        if let recording, recording.sharedSessionID != lease.sessionId { return }
        isFinishingCapture = true
        defer { isFinishingCapture = false }
        heartbeat?.cancel(); heartbeat = nil; watchdog?.invalidate(); watchdog = nil
        leaseDeadline.invalidate()
        await segmentStartTask?.value
        segmentStartTask = nil
        if let recording { await sendSegment(recording: recording, terminal: true) }
        if let config = credentials { _ = try? await request("/lease/release", method: "POST", body: lease.proof, config: config) }
        if ownedLease?.leaseId == lease.leaseId { ownedLease = nil; recordingSegmentID = nil; recordingStartMs = nil }
        await refresh()
    }

    func captureFailed() async {
        // A shared caller must never release another recording's ownership.
        guard !RecordingService.shared.isRecording, RecordingService.shared.state != .stopping else { return }
        await captureFinished(nil)
    }

    private func beginAction() {
        actionErrorMessage = nil
        refreshErrorMessage = nil
        publishError()
    }

    private func setActionError(_ message: String?) {
        actionErrorMessage = message
        publishError()
    }

    private func publishError() {
        errorMessage = actionErrorMessage ?? refreshErrorMessage
        if errorMessage != nil { statusMessage = nil }
    }

    func stopRecording() { if isRecordingHere { RecordingService.shared.stop() } }

    private func createSession(title: String, project: String?, meetingURL: String?, start: Date, end: Date?) async throws -> SharedMeetingRecord {
        guard let config = credentials, let title = clean(title, limit: 180) else { throw SharedMeetingError.unavailable }
        let id = UUID().uuidString.lowercased()
        let content = SharedMeetingPayload(title: title, projectName: clean(project, limit: 80), meetingUrl: clean(meetingURL, limit: 2000),
            startAtMs: (start.timeIntervalSince1970 * 1000).rounded(), endAtMs: end.map { ($0.timeIntervalSince1970 * 1000).rounded() })
        let encrypted = try SharedMeetingCrypto.encrypt(encoder.encode(content), key: keyData(config), sessionID: id)
        _ = try await request("/sessions", method: "POST", body: ["id": id, "encryptedPayload": encrypted], config: config)
        return SharedMeetingRecord(id: id, title: content.title, projectName: content.projectName, meetingURL: content.meetingUrl,
                                    startAt: start, endAt: end, revision: 1)
    }

    private func claim(_ id: String) async throws {
        guard let config = credentials, ownedLease == nil else { throw SharedMeetingError.busy }
        let generation = epoch
        let began = ProcessInfo.processInfo.systemUptime
        let data = try await request("/lease/claim", method: "POST", body: ["sessionId": id], config: config)
        let lease = try decoder.decode(SharedRecordingLease.self, from: data)
        guard epoch == generation, credentials?.deviceId == config.deviceId, ownedLease == nil,
              lease.deviceId == config.deviceId, lease.sessionId == id, lease.generationToken != nil,
              leaseDeadline.grant(requestStarted: began, receivedAt: ProcessInfo.processInfo.systemUptime) else {
            _ = try? await request("/lease/release", method: "POST", body: lease.proof, config: config)
            throw SharedMeetingError.lostLease
        }
        ownedLease = lease; activeLease = lease
        startLeaseWatch()
    }

    private func startLeaseWatch() {
        heartbeat?.cancel(); watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.ownedLease != nil else { return }
                if !self.hasValidRecordingLease { self.loseLease(SharedMeetingError.lostLease.localizedDescription) }
            }
        }
        RunLoop.main.add(timer, forMode: .common); watchdog = timer
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, let lease = self.ownedLease, let config = self.credentials else { return }
                let began = ProcessInfo.processInfo.systemUptime
                do {
                    let data = try await self.request("/lease/renew", method: "POST", body: lease.proof, config: config)
                    guard !Task.isCancelled, self.ownedLease?.leaseId == lease.leaseId, self.hasValidRecordingLease else { return }
                    let value = try self.json(data)
                    if value["handoffRequested"] as? Bool == true {
                        self.loseLease("The recording is moving to your other device. This segment was saved on this Mac.")
                        return
                    }
                    guard self.leaseDeadline.grant(requestStarted: began, receivedAt: ProcessInfo.processInfo.systemUptime) else {
                        throw SharedMeetingError.lostLease
                    }
                } catch {
                    guard !Task.isCancelled, self.ownedLease?.leaseId == lease.leaseId else { return }
                    self.loseLease(SharedMeetingError.lostLease.localizedDescription)
                    return
                }
            }
        }
    }

    private func loseLease(_ message: String) {
        guard ownedLease != nil else { return }
        leaseDeadline.invalidate(); heartbeat?.cancel(); heartbeat = nil
        statusMessage = message
        if RecordingService.shared.isRecording { RecordingService.shared.stop(reason: .sharedSessionEnded) }
        else if RecordingService.shared.state != .preparing && RecordingService.shared.state != .stopping {
            Task { await captureFinished(nil) }
        }
    }

    private func sendSegment(recording: RecordingSession, terminal: Bool) async {
        guard let lease = ownedLease, let config = credentials, let id = recordingSegmentID, let began = recordingStartMs else { return }
        var value = lease.proof
        value["id"] = id; value["startedAtMs"] = began
        value["endedAtMs"] = terminal ? ((recording.endedAt ?? Date()).timeIntervalSince1970 * 1000).rounded() as Any : NSNull()
        value["status"] = terminal ? (recording.stopReason == .recorderFailed ? "interrupted" : "complete") : "recording"
        do {
            // POST is idempotent for the initial record; final PATCH preserves its identity.
            _ = try await request("/sessions/\(lease.sessionId)/segments" + (terminal ? "/\(id)" : ""),
                                  method: terminal ? "PATCH" : "POST", body: value, config: config)
        } catch { statusMessage = "Audio is saved on this Mac. Its shared status could not be updated." }
    }

    private func event(_ meeting: SharedMeetingRecord) -> UnifiedEvent {
        UnifiedEvent(dedupKey: "shared:\(meeting.id)", title: meeting.title,
                     startTs: meeting.startAt, endTs: meeting.endAt ?? Date(), isAllDay: false, status: "confirmed",
                     meetingURL: meeting.meetingURL, winnerAccountEmail: "", projectId: AliasStore.shared.projectID(for: meeting.projectName) ?? meeting.projectName, sourcesJSON: "[]")
    }
    private func payload(_ meeting: SharedMeetingRecord) -> SharedMeetingPayload {
        SharedMeetingPayload(title: meeting.title, projectName: meeting.projectName, meetingUrl: meeting.meetingURL,
                             startAtMs: (meeting.startAt.timeIntervalSince1970 * 1000).rounded(),
                             endAtMs: meeting.endAt.map { ($0.timeIntervalSince1970 * 1000).rounded() })
    }
    private func apply(_ state: SharedWorkspaceState, key: Data) {
        devices = state.devices.filter { $0.revokedAtMs == nil }
        meetings = state.sessions.compactMap { record in
            guard let data = try? SharedMeetingCrypto.decrypt(record.encryptedPayload, key: key, sessionID: record.id),
                  let value = try? decoder.decode(SharedMeetingPayload.self, from: data), value.v == 1 else { return nil }
            return SharedMeetingRecord(id: record.id, title: value.title, projectName: value.projectName, meetingURL: value.meetingUrl,
                startAt: Date(timeIntervalSince1970: value.startAtMs / 1000),
                endAt: value.endAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }, revision: record.revision)
        }.sorted { $0.startAt > $1.startAt }
        segments = state.segments; activeLease = state.activeLease
    }
    private func save(_ config: SharedCredentials) async throws {
        let data = try encoder.encode(config)
        guard let value = String(data: data, encoding: .utf8) else { throw SharedMeetingError.unavailable }
        do {
            try await KeychainStore.setAsync(value, account: Self.account)
        } catch {
            credentialLoadGeneration = UUID()
            credentials = nil
            credentialsLoadState = .failed(error.localizedDescription)
            throw error
        }
        epoch = UUID(); credentials = config
        credentialsLoadState = .paired
    }
    private func keyData(_ config: SharedCredentials) throws -> Data {
        guard let data = SharedMeetingCrypto.urlDecode(config.key), data.count == 32 else { throw SharedMeetingError.invalidInvitation }
        return data
    }
    private func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(limit))
    }
    private func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else { throw SharedMeetingError.unavailable }
        return value
    }
    private func json(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SharedMeetingError.unavailable }
        return value
    }
    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                         config: SharedCredentials?, authenticated: Bool = true) async throws -> Data {
        let base = config?.endpoint ?? Self.endpoint
        guard base == Self.endpoint else { throw SharedMeetingError.invalidInvitation }
        let route = config.map { "/v1/workspaces/\($0.workspaceId)" + path } ?? path
        guard let url = URL(string: base + route) else { throw SharedMeetingError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated, let config { request.setValue("Bearer \(config.deviceToken)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 2_000_000, let http = response as? HTTPURLResponse else { throw SharedMeetingError.unavailable }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? json(data)["error"] as? String) ?? "request_failed"
            throw SharedMeetingError.server(http.statusCode, message)
        }
        return data
    }
}
