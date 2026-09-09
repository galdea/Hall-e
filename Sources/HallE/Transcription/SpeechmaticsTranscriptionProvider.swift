import Foundation
import CryptoKit

enum SpeechmaticsRegion: String, CaseIterable, Codable, Identifiable {
    case us1
    case eu1
    case au1

    static let supportedRegions: [Self] = [.us1, .eu1]
    var isSupported: Bool { Self.supportedRegions.contains(self) }

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .us1: "US1 — United States"
        case .eu1: "EU1 — Europe"
        case .au1: "AU1 — Australia"
        }
    }
    var endpoint: URL { URL(string: "https://\(rawValue).asr.api.speechmatics.com/v2/jobs/")! }
    var consentProcessor: String { "Speechmatics \(rawValue.uppercased())" }
}

struct SpeechmaticsConfiguration: Equatable {
    static let model = "melia-1"
    static let schemaVersion = 1
    static let rateUSDPerHour = 0.129
    static let rateObservedAt = "2026-09-01"

    var region: SpeechmaticsRegion
    var timeout: TimeInterval = 60 * 60
    var pollWaitSeconds = 60

    var endpoint: URL { region.endpoint }
    var optionsFingerprint: String {
        "speechmatics-v\(Self.schemaVersion)|\(region.rawValue)|\(Self.model)|multi|speaker|prefer-current"
    }
    var optionsDigest: String {
        SHA256.hash(data: Data(optionsFingerprint.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static func estimatedCostUSD(duration: TimeInterval) -> Double {
        max(0, duration / 3600) * rateUSDPerHour
    }

    func jobConfig(reference: String) throws -> Data {
        let value: [String: Any] = [
            "type": "transcription",
            "transcription_config": [
                "model": Self.model,
                "language": "multi",
                "diarization": "speaker",
                "speaker_diarization_config": ["prefer_current_speaker": true],
            ],
            "tracking": ["reference": reference],
        ]
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}

enum SpeechmaticsError: Error, LocalizedError, Equatable {
    case consentRequired
    case missingAPIKey
    case regionRequired
    case modelTrainingConfirmationRequired
    case spendLimitExceeded(projected: Double, limit: Double)
    case retryable(status: Int?, retryAfter: Date?, message: String)
    case actionRequired(status: Int, message: String)
    case ambiguousSubmission(String)
    case rejected(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .consentRequired:
            "Speechmatics audio consent for the selected region is required."
        case .missingAPIKey:
            "A Speechmatics API key is required in macOS Keychain."
        case .regionRequired:
            "Select a supported Speechmatics region (United States or Europe) in Settings."
        case .modelTrainingConfirmationRequired:
            "Confirm that Speechmatics Model Training is off before uploading meeting audio."
        case .spendLimitExceeded(let projected, let limit):
            "Cloud transcription spend guard would reach $\(String(format: "%.2f", projected)) (limit $\(String(format: "%.2f", limit)))."
        case .retryable(_, _, let message), .ambiguousSubmission(let message),
             .rejected(let message), .invalidResponse(let message):
            message
        case .actionRequired(let status, let message):
            "Speechmatics requires attention (HTTP \(status)): \(message)"
        }
    }
}

struct SpeechmaticsTranscriptionProvider: TranscriptionProvider {
    let configuration: SpeechmaticsConfiguration
    let rawResponseDirectory: URL
    let duration: TimeInterval
    var session: URLSession = .shared
    var responseCache: URL? = nil

    typealias JobCreatedHandler = @MainActor (String) async -> Void

    func transcribe(fileURL: URL, sessionID: UUID, track: String) async throws -> Transcript {
        try await transcribe(fileURL: fileURL, sessionID: sessionID, track: track,
                             existingJobID: nil, onJobCreated: { _ in })
    }

    func transcribe(fileURL: URL, sessionID: UUID, track: String,
                    existingJobID: String?, onJobCreated: JobCreatedHandler) async throws -> Transcript {
        guard configuration.region.isSupported else { throw SpeechmaticsError.regionRequired }
        guard AppPreferences.speechmaticsRegion == configuration.region else {
            throw SpeechmaticsError.consentRequired
        }
        guard AppPreferences.speechmaticsModelTrainingConfirmedOff else {
            throw SpeechmaticsError.modelTrainingConfirmationRequired
        }
        guard AppPreferences.allowSpeechmaticsAudioTranscription else {
            throw SpeechmaticsError.consentRequired
        }
        guard let key = KeychainStore.get(account: KeychainStore.speechmaticsTranscriptionAccount),
              !key.isEmpty else { throw SpeechmaticsError.missingAPIKey }

        let digest = try DeepgramTranscriptionProvider.sha256(fileURL)
        if let transcript = try cachedTranscript(digest: digest, sessionID: sessionID, track: track) {
            return transcript
        }

        let bytes = ((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
        let estimate = SpeechmaticsConfiguration.estimatedCostUSD(duration: duration)
        let fingerprint = requestFingerprint(sessionID: sessionID, digest: digest, bytes: bytes)
        do {
            try CloudTranscriptionSpendLedger.authorize(
                provider: .speechmatics, estimateUSD: estimate, fingerprint: fingerprint,
                rateUSDPerHour: SpeechmaticsConfiguration.rateUSDPerHour,
                rateObservedAt: SpeechmaticsConfiguration.rateObservedAt)
        } catch CloudTranscriptionSpendError.limitExceeded(let projected, let limit) {
            throw SpeechmaticsError.spendLimitExceeded(projected: projected, limit: limit)
        }

        let jobID: String
        if let existingJobID, !existingJobID.isEmpty {
            jobID = existingJobID
        } else {
            jobID = try await createJob(fileURL: fileURL, key: key, fingerprint: fingerprint)
            await onJobCreated(jobID)
        }

        try await waitUntilDone(jobID: jobID, key: key)
        let data = try await retrieveTranscript(jobID: jobID, key: key)
        let rawName = "speechmatics-response-\(digest.prefix(12)).json"
        try persist(data: data, at: rawResponseDirectory.appendingPathComponent(rawName))
        if let cached = cachedResponseURL(digest: digest) { try? persist(data: data, at: cached) }

        let decoded: SpeechmaticsTranscriptResponse
        do { decoded = try JSONDecoder().decode(SpeechmaticsTranscriptResponse.self, from: data) }
        catch {
            throw SpeechmaticsError.invalidResponse(
                "Speechmatics returned an unreadable transcript; the active transcript was preserved.")
        }
        var transcript = try normalize(decoded, sessionID: sessionID, track: track,
                                       digest: digest, rawName: rawName)
        transcript.providerMetadata?.requestID = jobID
        CloudTranscriptionSpendLedger.complete(provider: .speechmatics, estimateUSD: estimate,
                                                fingerprint: fingerprint, requestID: jobID)
        return transcript
    }

    func cachedResponseURL(digest: String) -> URL? {
        responseCache?.appendingPathComponent("speechmatics-\(configuration.optionsDigest)-\(digest).json")
    }

    func cachedTranscript(digest: String, sessionID: UUID, track: String) throws -> Transcript? {
        guard let cached = cachedResponseURL(digest: digest),
              let data = try? Data(contentsOf: cached),
              let decoded = try? JSONDecoder().decode(SpeechmaticsTranscriptResponse.self, from: data) else {
            return nil
        }
        var transcript = try normalize(decoded, sessionID: sessionID, track: track,
                                       digest: digest, rawName: cached.lastPathComponent)
        transcript.providerMetadata?.reusedCachedResponse = true
        return transcript
    }

    private func createJob(fileURL: URL, key: String, fingerprint: String) async throws -> String {
        let boundary = "HallE-\(UUID().uuidString)"
        let bodyURL = try multipartBody(fileURL: fileURL, boundary: boundary, fingerprint: fingerprint)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "wait", value: "0"),
                                 URLQueryItem(name: "format", value: "json-v2")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.upload(for: request, fromFile: bodyURL) }
        catch {
            CloudTranscriptionSpendLedger.markAmbiguous(fingerprint: fingerprint)
            throw SpeechmaticsError.ambiguousSubmission(
                "Speechmatics may have created a paid job, but Hall-e did not receive its ID. The job will not be uploaded again automatically.")
        }
        guard let http = response as? HTTPURLResponse else {
            CloudTranscriptionSpendLedger.markAmbiguous(fingerprint: fingerprint)
            throw SpeechmaticsError.ambiguousSubmission(
                "Speechmatics returned no HTTP response, so Hall-e cannot safely repeat the upload.")
        }
        guard http.statusCode == 201 else {
            if (500...599).contains(http.statusCode) {
                CloudTranscriptionSpendLedger.markAmbiguous(fingerprint: fingerprint)
                throw SpeechmaticsError.ambiguousSubmission(
                    "Speechmatics returned a server error without a job ID, so Hall-e cannot safely repeat the upload.")
            }
            throw classify(http: http, data: data)
        }
        guard let created = try? JSONDecoder().decode(SpeechmaticsCreateJobResponse.self, from: data),
              !created.id.isEmpty else {
            CloudTranscriptionSpendLedger.markAmbiguous(fingerprint: fingerprint)
            throw SpeechmaticsError.ambiguousSubmission(
                "Speechmatics accepted the upload without a readable job ID; Hall-e will not upload it again automatically.")
        }
        return created.id
    }

    private func waitUntilDone(jobID: String, key: String) async throws {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            var components = URLComponents(url: jobURL(jobID), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "wait", value: String(configuration.pollWaitSeconds))]
            let (data, http) = try await get(url: components.url!, key: key)
            guard (200..<300).contains(http.statusCode) else { throw classify(http: http, data: data) }
            guard let response = try? JSONDecoder().decode(SpeechmaticsJobStatusResponse.self, from: data) else {
                throw SpeechmaticsError.invalidResponse("Speechmatics returned unreadable job status.")
            }
            switch response.job.status {
            case "done": return
            case "rejected", "deleted":
                let detail = response.job.errors?.map(\.message).joined(separator: "; ")
                    ?? "Speechmatics could not process this recording."
                throw SpeechmaticsError.rejected(detail)
            default: continue
            }
        }
        throw SpeechmaticsError.retryable(status: nil, retryAfter: Date().addingTimeInterval(60),
                                           message: "Speechmatics is still processing this recording.")
    }

    private func retrieveTranscript(jobID: String, key: String) async throws -> Data {
        var components = URLComponents(url: jobURL(jobID).appendingPathComponent("transcript"),
                                      resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "wait", value: String(configuration.pollWaitSeconds)),
                                 URLQueryItem(name: "format", value: "json-v2")]
        let (data, http) = try await get(url: components.url!, key: key)
        guard (200..<300).contains(http.statusCode) else { throw classify(http: http, data: data) }
        return data
    }

    private func get(url: URL, key: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SpeechmaticsError.retryable(status: nil, retryAfter: nil,
                                                   message: "Speechmatics returned no HTTP response.")
            }
            return (data, http)
        } catch let error as SpeechmaticsError { throw error }
        catch {
            throw SpeechmaticsError.retryable(status: nil, retryAfter: Date().addingTimeInterval(30),
                                               message: "Speechmatics job retrieval was interrupted and can be resumed.")
        }
    }

    private func classify(http: HTTPURLResponse, data: Data) -> SpeechmaticsError {
        let envelope = try? JSONDecoder().decode(SpeechmaticsErrorEnvelope.self, from: data)
        let message = envelope?.message ?? envelope?.error ?? "Request rejected"
        if http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode) {
            return .retryable(status: http.statusCode,
                              retryAfter: DeepgramTranscriptionProvider.retryAfter(
                                http.value(forHTTPHeaderField: "Retry-After")),
                              message: "Speechmatics temporarily rejected the request (HTTP \(http.statusCode)).")
        }
        return .actionRequired(status: http.statusCode, message: message)
    }

    func normalize(_ response: SpeechmaticsTranscriptResponse, sessionID: UUID, track: String,
                   digest: String, rawName: String? = nil) throws -> Transcript {
        var speakerIndexes: [String: Int] = [:]
        func speakerIndex(_ label: String?) -> Int? {
            guard let label, !label.isEmpty, label != "UU" else { return nil }
            if let existing = speakerIndexes[label] { return existing }
            let next = speakerIndexes.count
            speakerIndexes[label] = next
            return next
        }

        var words: [TranscriptWord] = []
        var segments: [TranscriptSegment] = []
        var segmentText = ""
        var segmentStart: Double?
        var segmentEnd: Double = 0
        var segmentSpeaker: Int?

        func flushSegment() {
            let text = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = segmentStart, !text.isEmpty {
                segments.append(.init(start: start, duration: max(0, segmentEnd - start), text: text,
                                      track: track, speaker: segmentSpeaker, speakerConfidence: nil))
            }
            segmentText = ""; segmentStart = nil; segmentEnd = 0; segmentSpeaker = nil
        }
        func append(_ content: String, attachesToPrevious: Bool) {
            if segmentText.isEmpty { segmentText = content }
            else if attachesToPrevious { segmentText += content }
            else { segmentText += " " + content }
        }

        var sawSpeech = false
        for result in response.results {
            guard let alternative = result.alternatives.first else { continue }
            let isWord = result.type == "word"
            let isPunctuation = result.type == "punctuation"
            guard isWord || isPunctuation else { continue }

            if isWord {
                sawSpeech = true
                let speaker = speakerIndex(alternative.speaker)
                if segmentStart != nil, speaker != segmentSpeaker { flushSegment() }
                if segmentStart == nil {
                    segmentStart = result.startTime
                    segmentSpeaker = speaker
                }
                segmentEnd = max(segmentEnd, result.endTime)
                append(alternative.content, attachesToPrevious: false)
                words.append(.init(word: alternative.content, punctuatedWord: alternative.content,
                                   start: result.startTime, end: result.endTime,
                                   confidence: alternative.confidence, speaker: speaker,
                                   speakerConfidence: nil))
            } else {
                segmentEnd = max(segmentEnd, result.endTime)
                append(alternative.content, attachesToPrevious: result.attachesTo == "previous")
                if result.attachesTo == "previous", !words.isEmpty {
                    words[words.count - 1].punctuatedWord = (words.last?.punctuatedWord ?? words.last!.word)
                        + alternative.content
                }
            }
            if result.isEOS == true { flushSegment() }
        }
        flushSegment()

        if sawSpeech && (words.isEmpty || words.contains(where: { $0.speaker == nil })
                         || segments.isEmpty || segments.contains(where: { $0.speaker == nil })) {
            throw SpeechmaticsError.invalidResponse(
                "Speechmatics returned speech without complete speaker diarization; the active transcript was preserved.")
        }
        return Transcript(sessionID: sessionID, localeUsed: "multi", segments: segments,
                          status: .completed, source: "speechmatics:\(SpeechmaticsConfiguration.model)",
                          words: words,
                          providerMetadata: .init(provider: "speechmatics",
                                                  model: SpeechmaticsConfiguration.model,
                                                  requestID: response.job?.id, createdAt: Date(),
                                                  audioSHA256: digest,
                                                  optionsFingerprint: configuration.optionsFingerprint,
                                                  rawResponseFileName: rawName))
    }

    private func requestFingerprint(sessionID: UUID, digest: String, bytes: Int64) -> String {
        "speechmatics|\(sessionID.uuidString)|\(digest)|\(bytes)|\(String(format: "%.3f", duration))|\(configuration.optionsFingerprint)"
    }

    private func jobURL(_ id: String) -> URL { configuration.endpoint.appendingPathComponent(id) }

    private func persist(data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func multipartBody(fileURL: URL, boundary: String, fingerprint: String) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("halle-speechmatics-\(UUID().uuidString).multipart")
        do {
            _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            func write(_ value: String) throws { try output.write(contentsOf: Data(value.utf8)) }

            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"config\"\r\nContent-Type: application/json\r\n\r\n")
            try output.write(contentsOf: configuration.jobConfig(reference: fingerprint))
            try write("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"data_file\"; filename=\"\(fileURL.lastPathComponent)\"\r\nContent-Type: \(DeepgramTranscriptionProvider.contentType(for: fileURL))\r\n\r\n")
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try write("\r\n--\(boundary)--\r\n")
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}

struct SpeechmaticsTranscriptResponse: Codable {
    var format: String?
    var job: Job?
    var results: [Result]

    struct Job: Codable { var id: String? }
    struct Result: Codable {
        var alternatives: [Alternative]
        var startTime: Double
        var endTime: Double
        var type: String
        var attachesTo: String?
        var isEOS: Bool?
        enum CodingKeys: String, CodingKey {
            case alternatives, type
            case startTime = "start_time"
            case endTime = "end_time"
            case attachesTo = "attaches_to"
            case isEOS = "is_eos"
        }
    }
    struct Alternative: Codable {
        var confidence: Double?
        var content: String
        var language: String?
        var speaker: String?
    }
}

private struct SpeechmaticsCreateJobResponse: Codable { var id: String; var status: String? }
private struct SpeechmaticsJobStatusResponse: Codable {
    var job: Job
    struct Job: Codable {
        var id: String
        var status: String
        var errors: [JobError]?
    }
    struct JobError: Codable { var message: String }
}
private struct SpeechmaticsErrorEnvelope: Codable { var message: String?; var error: String? }
