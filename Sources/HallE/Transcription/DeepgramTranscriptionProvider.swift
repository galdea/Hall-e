import Foundation
import CryptoKit

struct DeepgramConfiguration: Equatable {
    static let model = "nova-3"
    static let schemaVersion = 1
    static let transcriptionRatePerMinute = 0.0058
    static let diarizationRatePerMinute = 0.0020

    var endpoint = URL(string: "https://api.deepgram.com/v1/listen")!
    var keyterms: [String] = []
    var timeout: TimeInterval = 60 * 60

    var optionsFingerprint: String {
        let terms = keyterms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.sorted().joined(separator: "|")
        return "deepgram-v\(Self.schemaVersion)|\(Self.model)|multi|smart|utterances|diarize-v2|mip-opt-out|\(terms)"
    }

    /// Filesystem-safe digest of `optionsFingerprint`, used to key the cache so a
    /// model/option change never reuses a response produced under other options.
    var optionsDigest: String {
        SHA256.hash(data: Data(optionsFingerprint.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    func requestURL() -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "model", value: Self.model),
            URLQueryItem(name: "language", value: "multi"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "diarize_model", value: "v2"),
            URLQueryItem(name: "mip_opt_out", value: "true"),
        ]
        items += keyterms.map { URLQueryItem(name: "keyterm", value: $0) }
        components.queryItems = items
        return components.url!
    }

    static func estimatedCostUSD(duration: TimeInterval) -> Double {
        max(0, duration / 60) * (transcriptionRatePerMinute + diarizationRatePerMinute)
    }
}

enum DeepgramError: Error, LocalizedError, Equatable {
    case consentRequired
    case missingAPIKey
    case spendLimitExceeded(projected: Double, limit: Double)
    /// The Deepgram account itself is out of credit. Distinct from a generic
    /// action-required failure so it can raise a specific alert.
    case creditExhausted(String)
    case retryable(status: Int?, retryAfter: Date?, message: String)
    case actionRequired(status: Int, code: String?)
    case ambiguousBilling(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .consentRequired: "Cloud audio consent is required before uploading a recording."
        case .missingAPIKey: "A rotated Deepgram API key is required in macOS Keychain."
        case .spendLimitExceeded(let projected, let limit):
            "Deepgram monthly spend guard would reach $\(String(format: "%.2f", projected)) (limit $\(String(format: "%.2f", limit)))."
        case .creditExhausted(let message): message
        case .retryable(_, _, let message): message
        case .actionRequired(let status, _): "Deepgram requires attention (HTTP \(status))."
        case .ambiguousBilling(let message): message
        case .invalidResponse(let message): message
        }
    }
}

struct DeepgramTranscriptionProvider: TranscriptionProvider {
    let configuration: DeepgramConfiguration
    let rawResponseDirectory: URL
    let duration: TimeInterval
    var session: URLSession = .shared
    /// Where successful raw responses are kept for reuse. `nil` disables reuse.
    /// Callers opt in explicitly so constructing a provider never touches disk.
    var responseCache: URL? = nil

    /// The keys to try, in order. The fallback is only reached when the primary
    /// reports exhausted credit — never on an auth error, a bad request, or a
    /// transient failure, so a misconfigured primary cannot silently drain the
    /// spare account.
    struct Credential: Equatable {
        var label: String
        var key: String
    }

    static func credentials() -> [Credential] {
        var result: [Credential] = []
        if let primary = KeychainStore.get(account: KeychainStore.deepgramTranscriptionAccount),
           !primary.isEmpty {
            result.append(.init(label: "primary", key: primary))
        }
        if let fallback = KeychainStore.get(account: KeychainStore.deepgramFallbackTranscriptionAccount),
           !fallback.isEmpty, !result.contains(where: { $0.key == fallback }) {
            result.append(.init(label: "fallback", key: fallback))
        }
        return result
    }

    func cachedResponseURL(digest: String) -> URL? {
        responseCache?.appendingPathComponent("deepgram-\(configuration.optionsDigest)-\(digest).json")
    }

    func transcribe(fileURL: URL, sessionID: UUID, track: String) async throws -> Transcript {
        guard AppPreferences.allowCloudAudioTranscription else { throw DeepgramError.consentRequired }
        let credentials = Self.credentials()
        guard !credentials.isEmpty else { throw DeepgramError.missingAPIKey }
        let digest = try Self.sha256(fileURL)

        // Reuse before spending. A cached response is the same audio under the
        // same options, so re-normalizing it is free and must not be billed or
        // counted against the monthly guard. Consent and the key are still
        // required above: revoking consent must stop Hall-e producing new
        // Deepgram transcripts, not merely stop new uploads.
        if let transcript = try cachedTranscript(digest: digest, sessionID: sessionID, track: track) {
            return transcript
        }

        let bytes = ((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
        let estimate = DeepgramConfiguration.estimatedCostUSD(duration: duration)
        let requestFingerprint = fingerprint(sessionID: sessionID, digest: digest, bytes: bytes)
        do {
            try CloudTranscriptionSpendLedger.authorize(
                provider: .deepgram, estimateUSD: estimate, fingerprint: requestFingerprint,
                rateUSDPerHour: (DeepgramConfiguration.transcriptionRatePerMinute
                                 + DeepgramConfiguration.diarizationRatePerMinute) * 60,
                rateObservedAt: "2026-08-09")
        } catch CloudTranscriptionSpendError.limitExceeded(let projected, let limit) {
            throw DeepgramError.spendLimitExceeded(projected: projected, limit: limit)
        }

        // Try each account in turn, but only step past one that is out of credit.
        var exhausted: DeepgramError?
        for credential in credentials {
            do {
                return try await send(fileURL: fileURL, sessionID: sessionID, track: track,
                                      credential: credential, digest: digest,
                                      estimate: estimate, requestFingerprint: requestFingerprint)
            } catch let error as DeepgramError {
                guard case .creditExhausted = error else { throw error }
                exhausted = error
                Log.rec.error("deepgram \(credential.label, privacy: .public) account is out of credit")
                continue
            }
        }
        throw exhausted ?? DeepgramError.missingAPIKey
    }

    /// One attempt with one account. Everything that must happen exactly once —
    /// hashing, cache reuse, spend authorization — has already happened.
    private func send(fileURL: URL, sessionID: UUID, track: String, credential: Credential,
                      digest: String, estimate: Double, requestFingerprint: String) async throws -> Transcript {
        var request = URLRequest(url: configuration.requestURL())
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("Token \(credential.key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.contentType(for: fileURL), forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: fileURL)
        } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
            CloudTranscriptionSpendLedger.markAmbiguous(fingerprint: requestFingerprint)
            throw DeepgramError.ambiguousBilling("Deepgram may have received the audio, but Hall-e lost the response. Review before retrying to avoid duplicate billing.")
        } catch {
            throw DeepgramError.retryable(status: nil, retryAfter: nil, message: "Deepgram upload failed before a response was received.")
        }

        guard let http = response as? HTTPURLResponse else {
            throw DeepgramError.retryable(status: nil, retryAfter: nil, message: "Deepgram returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(DeepgramErrorEnvelope.self, from: data)
            let code = envelope?.errCode ?? envelope?.error
            if http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode) {
                throw DeepgramError.retryable(status: http.statusCode,
                                              retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")),
                                              message: "Deepgram temporarily rejected the request (HTTP \(http.statusCode)).")
            }
            if Self.indicatesExhaustedCredit(status: http.statusCode, code: code,
                                             message: envelope?.errMsg ?? envelope?.error) {
                throw DeepgramError.creditExhausted(
                    "The Deepgram \(credential.label) account reported no remaining credit (HTTP \(http.statusCode)).")
            }
            throw DeepgramError.actionRequired(status: http.statusCode, code: code)
        }

        let rawName = "deepgram-response-\(digest.prefix(12)).json"
        let rawURL = rawResponseDirectory.appendingPathComponent(rawName)
        try FileManager.default.createDirectory(at: rawResponseDirectory, withIntermediateDirectories: true)
        try data.write(to: rawURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rawURL.path)

        // Best-effort: a cache-write failure must not discard a paid transcript.
        if let cached = cachedResponseURL(digest: digest) {
            try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? data.write(to: cached, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cached.path)
        }

        let decoded: DeepgramResponse
        do { decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data) }
        catch { throw DeepgramError.invalidResponse("Deepgram returned an unreadable response; the active transcript was preserved.") }
        var transcript = try normalize(decoded, sessionID: sessionID, track: track, digest: digest, rawName: rawName)
        transcript.providerMetadata?.credential = credential.label
        CloudTranscriptionSpendLedger.complete(provider: .deepgram, estimateUSD: estimate,
                                                fingerprint: requestFingerprint,
                                                requestID: decoded.metadata?.requestID)
        return transcript
    }

    /// Normalizes a previously persisted successful response for the same audio
    /// and options. Returns `nil` when nothing usable is cached. Performs no
    /// network request and touches no spend ledger.
    func cachedTranscript(digest: String, sessionID: UUID, track: String) throws -> Transcript? {
        guard let cached = cachedResponseURL(digest: digest),
              let data = try? Data(contentsOf: cached),
              let decoded = try? JSONDecoder().decode(DeepgramResponse.self, from: data) else { return nil }
        var transcript = try normalize(decoded, sessionID: sessionID, track: track,
                                       digest: digest, rawName: cached.lastPathComponent)
        transcript.providerMetadata?.reusedCachedResponse = true
        return transcript
    }

    func normalize(_ response: DeepgramResponse, sessionID: UUID, track: String,
                   digest: String, rawName: String? = nil) throws -> Transcript {
        guard let alternative = response.results?.channels?.first?.alternatives?.first else {
            throw DeepgramError.invalidResponse("Deepgram returned no transcript alternative.")
        }
        let words = (alternative.words ?? []).map {
            TranscriptWord(word: $0.word, punctuatedWord: $0.punctuatedWord, start: $0.start, end: $0.end,
                           confidence: $0.confidence, speaker: $0.speaker,
                           speakerConfidence: $0.speakerConfidence)
        }
        let utterances = response.results?.utterances ?? []
        let segments = utterances.map { utterance in
            let speakerEvidence = (alternative.words ?? []).filter {
                $0.speaker == utterance.speaker && $0.start >= utterance.start && $0.end <= utterance.end
            }.compactMap(\.speakerConfidence)
            let speakerConfidence = speakerEvidence.isEmpty ? nil : speakerEvidence.reduce(0, +) / Double(speakerEvidence.count)
            return TranscriptSegment(start: utterance.start, duration: max(0, utterance.end - utterance.start), text: utterance.transcript,
                                     track: track, speaker: utterance.speaker,
                                     speakerConfidence: speakerConfidence)
        }
        let nonEmpty = !(alternative.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if nonEmpty && (words.isEmpty || words.contains(where: { $0.speaker == nil }) || segments.isEmpty) {
            throw DeepgramError.invalidResponse("Deepgram returned speech without complete diarization; the active transcript was preserved.")
        }
        return Transcript(sessionID: sessionID, localeUsed: "multi", segments: segments,
                          status: .completed, source: "deepgram:\(DeepgramConfiguration.model)", words: words,
                          providerMetadata: .init(provider: "deepgram", model: DeepgramConfiguration.model,
                                                  requestID: response.metadata?.requestID, createdAt: Date(),
                                                  audioSHA256: digest,
                                                  optionsFingerprint: configuration.optionsFingerprint,
                                                  rawResponseFileName: rawName))
    }

    private func fingerprint(sessionID: UUID, digest: String, bytes: Int64) -> String {
        "\(sessionID.uuidString)|\(digest)|\(bytes)|\(String(format: "%.3f", duration))|\(configuration.optionsFingerprint)"
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 1024 * 1024)
            guard let chunk, !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        default: "audio/mp4"
        }
    }

    /// HTTP 402 is Deepgram's payment-required signal. Some plans instead answer
    /// 403 with a credit-specific code or message, so both are matched — but only
    /// on credit wording, never on a bare 403, which is ordinary authorization.
    static func indicatesExhaustedCredit(status: Int, code: String?, message: String?) -> Bool {
        if status == 402 { return true }
        let haystack = [code, message].compactMap { $0 }.joined(separator: " ").lowercased()
        guard !haystack.isEmpty else { return false }
        return haystack.contains("insufficient_credit")
            || haystack.contains("insufficient credit")
            || haystack.contains("out of credit")
            || haystack.contains("no credit")
            || haystack.contains("credit_limit")
            || haystack.contains("quota_exceeded")
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> Date? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) { return now.addingTimeInterval(seconds) }
        return HTTPDateParser.date(value)
    }
}

private enum HTTPDateParser {
    static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}

struct DeepgramResponse: Codable {
    var metadata: Metadata?
    var results: Results?
    struct Metadata: Codable { var requestID: String?; enum CodingKeys: String, CodingKey { case requestID = "request_id" } }
    struct Results: Codable { var channels: [Channel]?; var utterances: [Utterance]? }
    struct Channel: Codable { var alternatives: [Alternative]? }
    struct Alternative: Codable { var transcript: String?; var words: [Word]? }
    struct Word: Codable {
        var word: String; var punctuatedWord: String?; var start: Double; var end: Double
        var confidence: Double?; var speaker: Int?; var speakerConfidence: Double?
        enum CodingKeys: String, CodingKey {
            case word, start, end, confidence, speaker
            case punctuatedWord = "punctuated_word"
            case speakerConfidence = "speaker_confidence"
        }
    }
    struct Utterance: Codable {
        var start: Double; var end: Double; var transcript: String; var speaker: Int?; var confidence: Double?
    }
}

private struct DeepgramErrorEnvelope: Codable {
    var errCode: String?
    var errMsg: String?
    var error: String?
    enum CodingKeys: String, CodingKey {
        case errCode = "err_code"
        case errMsg = "err_msg"
        case error
    }
}
