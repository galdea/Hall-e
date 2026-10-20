import AppKit
import CryptoKit
import Foundation

private final class PhoneTransferNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct PhoneAudioTransferCredentials: Decodable {
    let endpoint: String
    let workspaceId: String
    let deviceId: String
    let deviceToken: String
    let key: String
    let owner: Bool

    static func validated(_ raw: String) -> Self? {
        guard raw.utf8.count <= 8192, let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              SharedMeetingCoordinator.isAllowedCoordinatorEndpoint(value.endpoint),
              UUID(uuidString: value.workspaceId) != nil, UUID(uuidString: value.deviceId) != nil,
              (40...60).contains(value.deviceToken.count),
              value.deviceToken.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
              }),
              let key = SharedMeetingCrypto.urlDecode(value.key), key.count == 32 else { return nil }
        return value
    }
}

enum PhoneAudioTransferCrypto {
    static func deriveKey(_ key: Data, purpose: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("halle-phone-audio-key-v1\n\(purpose)".utf8),
            using: SymmetricKey(data: key)))
    }

    static func chunkAAD(fields: [String], index: Int) -> Data {
        Data(("halle-phone-audio-v1\n" + fields.joined(separator: "\n") + "\n" + String(index)).utf8)
    }

    static func decryptChunk(_ encrypted: Data, key: Data, fields: [String], index: Int) throws -> Data {
        guard encrypted.count >= 28 else { throw TransferCryptoError.invalidChunk }
        let aad = chunkAAD(fields: fields, index: index)
        let nonce = try AES.GCM.Nonce(data: encrypted.prefix(12))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encrypted.dropFirst(12).dropLast(16), tag: encrypted.suffix(16))
        return try AES.GCM.open(box, using: SymmetricKey(data: deriveKey(key, purpose: "audio-encryption")), authenticating: aad)
    }

    static func receiptMAC(key: Data, canonical: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: deriveKey(key, purpose: "transcript-receipt"))))
    }

    static func manifestMAC(key: Data, canonical: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: deriveKey(key, purpose: "manifest-binding"))))
    }

    static func isMeaningfulTranscript(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func storedReceiptMatches(_ receipt: [String: Any], fields: [String], transcriptHash: String, key: Data) -> Bool {
        guard fields.count == 11,
              (receipt["v"] as? Int) == 1, (receipt["protocolVersion"] as? Int) == 1,
              (receipt["transferId"] as? String) == fields[2], (receipt["workspaceId"] as? String) == fields[3],
              (receipt["deviceId"] as? String) == fields[4], (receipt["macDeviceId"] as? String) == fields[5],
              (receipt["recordingId"] as? String) == fields[6], (receipt["audioSHA256"] as? String) == fields[7],
              (receipt["plaintextLength"] as? Int) == Int(fields[8]), (receipt["chunkSize"] as? Int) == Int(fields[9]),
              (receipt["chunkCount"] as? Int) == Int(fields[10]),
              let savedAtMs = receipt["savedAtMs"] as? Int, savedAtMs > 0,
              (receipt["transcriptSHA256"] as? String) == transcriptHash,
              (receipt["macAudioPurged"] as? Bool) == true,
              let encodedMAC = receipt["mac"] as? String,
              let suppliedMAC = SharedMeetingCrypto.urlDecode(encodedMAC) else { return false }
        let values = ["1", "1", fields[2], fields[3], fields[4], fields[5], fields[6], fields[7],
            fields[8], fields[9], fields[10], transcriptHash, "true", String(savedAtMs)]
        let canonical = "halle-phone-audio-receipt-v1\n" + values.joined(separator: "\n")
        return HMAC<SHA256>.isValidAuthenticationCode(suppliedMAC, authenticating: Data(canonical.utf8),
            using: SymmetricKey(data: deriveKey(key, purpose: "transcript-receipt")))
    }

    enum TransferCryptoError: Error { case invalidChunk }
}

/// Receives explicitly queued phone audio, transcribes it on this Mac, and
/// publishes a deletion receipt only after transcript.json survives readback.
@MainActor
final class PhoneAudioTransferService {
    static let shared = PhoneAudioTransferService()
    private let session: URLSession
    private var task: Task<Void, Never>?
    private struct Manifest: Decodable {
        let v: Int; let protocolVersion: Int; let transferId: String; let workspaceId: String; let deviceId: String
        let macDeviceId: String; let recordingId: String; let audioSHA256: String
        let plaintextLength: Int; let chunkSize: Int; let chunkCount: Int; let complete: Bool
    }

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 180
        config.httpCookieStorage = nil; config.urlCache = nil
        session = URLSession(configuration: config, delegate: PhoneTransferNoRedirect(), delegateQueue: nil)
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            defer { self?.task = nil }
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func pollOnce() async {
        do {
            guard let raw = try await KeychainStore.getAsync(account: "shared-meetings-v1"),
                  let c = PhoneAudioTransferCredentials.validated(raw) else { return }
            _ = try await request("/transfers/consumer", method: "POST", config: c, body: [:])
            let listing = try await request("/transfers", config: c)
            let transfers = (listing["transfers"] as? [[String: Any]] ?? []).compactMap { try? JSONDecoder().decode(Manifest.self, from: JSONSerialization.data(withJSONObject: $0)) }
            for manifest in transfers where manifest.complete && manifest.macDeviceId == c.deviceId {
                do { try await importTransfer(manifest, config: c) }
                catch {
                    Log.rec.warning("phone transfer \(manifest.transferId, privacy: .public) remains queued for retry: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Log.rec.warning("phone transfer check failed; queued recordings remain on the phone: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func importTransfer(_ m: Manifest, config c: PhoneAudioTransferCredentials) async throws {
        guard m.v == 1, m.protocolVersion == 1, m.workspaceId == c.workspaceId, m.macDeviceId == c.deviceId,
              m.chunkSize == 256 * 1024, m.chunkCount == (m.plaintextLength + m.chunkSize - 1) / m.chunkSize,
              (1...100 * 1024 * 1024).contains(m.plaintextLength), m.chunkCount <= 400,
              let audioID = UUID(uuidString: m.recordingId), UUID(uuidString: m.transferId) != nil,
              let key = SharedMeetingCrypto.urlDecode(c.key), key.count == 32 else { throw TransferError.invalidManifest }
        let partialRoot = AppPaths.appSupport.appendingPathComponent("PhoneTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: partialRoot, withIntermediateDirectories: true)
        let fields = manifestCanonicalFields(m)
        let canonicalManifest = "halle-phone-audio-manifest-v1\n" + fields.joined(separator: "\n")
        let manifestSidecar = partialRoot.appendingPathComponent(m.transferId + ".manifest.json")
        let signedManifest: [String: String] = [
            "canonical": canonicalManifest,
            "mac": SharedMeetingCrypto.urlEncode(PhoneAudioTransferCrypto.manifestMAC(key: key, canonical: canonicalManifest))
        ]
        let signedManifestBytes = try JSONSerialization.data(withJSONObject: signedManifest, options: [.sortedKeys])
        if let prior = try? Data(contentsOf: manifestSidecar) {
            guard prior == signedManifestBytes else { throw TransferError.invalidManifest }
        } else {
            try signedManifestBytes.write(to: manifestSidecar, options: .atomic)
            guard try Data(contentsOf: manifestSidecar) == signedManifestBytes else { throw TransferError.invalidManifest }
        }
        let partial = partialRoot.appendingPathComponent(m.transferId + ".m4a")
        if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: Data()) }
        var existingLength = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int) ?? 0
        if existingLength > m.plaintextLength || (existingLength != m.plaintextLength && existingLength % m.chunkSize != 0) {
            try Data().write(to: partial, options: .atomic); existingLength = 0
        }
        var audio = try Data(contentsOf: partial)
        audio.reserveCapacity(m.plaintextLength)
        for index in 0..<m.chunkCount {
            if index * m.chunkSize < existingLength { continue }
            let encrypted = try await binary("/transfers/\(m.transferId)/chunks/\(index)", config: c)
            guard encrypted.count >= 28 else { throw TransferError.invalidChunk }
            let plain = try PhoneAudioTransferCrypto.decryptChunk(encrypted, key: key, fields: fields, index: index)
            let expected = index == m.chunkCount - 1 ? m.plaintextLength - index * m.chunkSize : m.chunkSize
            guard plain.count == expected else { throw TransferError.invalidChunk }
            audio.append(plain)
            try audio.write(to: partial, options: .atomic)
        }
        guard audio.count == m.plaintextLength else { throw TransferError.audioHashMismatch }
        guard sha256(audio) == m.audioSHA256 else {
            try Data().write(to: partial, options: .atomic)
            throw TransferError.audioHashMismatch
        }

        let sessionRecord = try await importedSession(transfer: m, audioFile: partial, config: c, audioId: audioID)
        if TranscriptStore.load(sessionRecord)?.status != .completed {
            await RecordingCoordinator.resumeQueuedJobsWhenIdle()
        }
        guard let librarySession = RecordingStore.allSessions().first(where: { $0.eventDedupKey == "phone-transfer:\(m.transferId)" }),
              librarySession.transcriptStatus == .completed,
              let libraryTranscript = TranscriptStore.load(librarySession), libraryTranscript.status == .completed else {
            throw TransferError.sessionNotDurable
        }
        let transcriptBytes = try Data(contentsOf: librarySession.transcriptFileURL)
        let transcriptHash = sha256(transcriptBytes)
        guard PhoneAudioTransferCrypto.isMeaningfulTranscript(libraryTranscript.plainText) else {
            throw TransferError.emptyTranscript
        }
        let receiptFile = partialRoot.appendingPathComponent(m.transferId + ".receipt.json")
        let receiptFields: [(String, Any)] = [("v", 1), ("protocolVersion", 1), ("transferId", m.transferId),
            ("workspaceId", c.workspaceId), ("deviceId", m.deviceId), ("macDeviceId", c.deviceId),
            ("recordingId", m.recordingId), ("audioSHA256", m.audioSHA256), ("plaintextLength", m.plaintextLength),
            ("chunkSize", m.chunkSize), ("chunkCount", m.chunkCount)]
        let priorReceipt: [String: Any]?
        if FileManager.default.fileExists(atPath: receiptFile.path) {
            guard let prior = try? Data(contentsOf: receiptFile),
                  let value = try? JSONSerialization.jsonObject(with: prior) as? [String: Any],
                  PhoneAudioTransferCrypto.storedReceiptMatches(value, fields: receiptFields.map { String(describing: $0.1) },
                      transcriptHash: transcriptHash, key: key) else { throw TransferError.invalidStoredReceipt }
            priorReceipt = value
        } else {
            priorReceipt = nil
        }
        // The phone only deletes after receipt, so the Mac can now clean its
        // imported audio copies. The library session and transcript are durable.
        let libraryAudio = librarySession.folderURL.appendingPathComponent("phone.m4a")
        if FileManager.default.fileExists(atPath: libraryAudio.path) { try FileManager.default.removeItem(at: libraryAudio) }
        if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
        guard !FileManager.default.fileExists(atPath: libraryAudio.path),
              !FileManager.default.fileExists(atPath: partial.path) else { throw TransferError.macAudioCleanupFailed }
        let receipt: [String: Any]
        if let priorReceipt {
            receipt = priorReceipt
        } else {
            let fields: [(String, Any)] = receiptFields + [("transcriptSHA256", transcriptHash),
                ("macAudioPurged", true),
                ("savedAtMs", Int(Date().timeIntervalSince1970 * 1000))]
            let canonical = "halle-phone-audio-receipt-v1\n" + fields.map { String(describing: $0.1) }.joined(separator: "\n")
            let hmac = PhoneAudioTransferCrypto.receiptMAC(key: key, canonical: canonical)
            var value = Dictionary(uniqueKeysWithValues: fields)
            value["mac"] = SharedMeetingCrypto.urlEncode(Data(hmac))
            receipt = value
            let savedReceipt = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try savedReceipt.write(to: receiptFile, options: .atomic)
        }
        _ = try await request("/transfers/\(m.transferId)/receipt", method: "POST", config: c, body: ["receipt": receipt])
        NotificationCenter.default.post(name: .halleRecordingChanged, object: nil)
    }

    private func importedSession(transfer m: Manifest, audioFile: URL, config c: PhoneAudioTransferCredentials, audioId: UUID) async throws -> RecordingSession {
        if let old = RecordingStore.allSessions().first(where: { $0.eventDedupKey == "phone-transfer:\(m.transferId)" }) { return old }
        var title = "Phone recording"
        var project: String?
        var start = Date()
        if let state = try? await request("/state", config: c),
           let session = (state["sessions"] as? [[String: Any]])?.first(where: { $0["id"] as? String == m.recordingId }),
           let encrypted = session["encryptedPayload"] as? String,
           let key = SharedMeetingCrypto.urlDecode(c.key),
           let clear = try? SharedMeetingCrypto.decrypt(encrypted, key: key, sessionID: m.recordingId),
           let payload = try? JSONSerialization.jsonObject(with: clear) as? [String: Any] {
            title = payload["title"] as? String ?? title
            if let projectName = payload["projectName"] as? String {
                project = AliasStore.shared.projects.first(where: { $0.matchesReference(projectName) })?.id
            }
            if let ms = payload["startAtMs"] as? Double { start = Date(timeIntervalSince1970: ms / 1000) }
        }
        let event = UnifiedEvent(dedupKey: "phone-transfer:\(m.transferId)", title: title, startTs: start,
            endTs: start.addingTimeInterval(1), isAllDay: false, status: "confirmed", effectiveResponse: nil,
            meetingURL: nil, location: nil, descriptionText: nil, htmlLink: nil, organizerEmail: nil,
            attendeesJSON: nil, iCalUID: nil, winnerAccountEmail: "", projectId: project,
            projectConfidence: nil, sourcesJSON: "[]")
        var local = RecordingSession(event: event, notePath: nil, sourceKind: .manual)
        local.sharedSessionID = m.recordingId
        local.transcriptionJob?.allowTranscriptTextAI = false
        local.startedAt = start; local.endedAt = Date(); local.state = .completed
        local.playbackFileName = "phone.m4a"; local.systemAudioFileName = "phone.m4a"
        try FileManager.default.createDirectory(at: local.folderURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: audioFile, to: local.folderURL.appendingPathComponent("phone.m4a"))
        try local.persist()
        guard RecordingStore.allSessions().contains(where: { $0.eventDedupKey == local.eventDedupKey }) else {
            throw TransferError.sessionNotDurable
        }
        return local
    }

    private func request(_ path: String, method: String = "GET", config c: PhoneAudioTransferCredentials,
                         body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = transferURL(path, config: c) else { throw TransferError.invalidCredentials }
        var req = URLRequest(url: url); req.httpMethod = method
        req.setValue("Bearer \(c.deviceToken)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TransferError.requestFailed }
        return object
    }
    private func binary(_ path: String, config c: PhoneAudioTransferCredentials) async throws -> Data {
        guard let url = transferURL(path, config: c) else { throw TransferError.invalidCredentials }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(c.deviceToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw TransferError.requestFailed }
        return data
    }
    private func transferURL(_ path: String, config c: PhoneAudioTransferCredentials) -> URL? {
        guard path.hasPrefix("/"), var components = URLComponents(string: c.endpoint),
              SharedMeetingCoordinator.isAllowedCoordinatorEndpoint(c.endpoint),
              components.scheme == "https" || components.scheme == "http",
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { return nil }
        components.path = "/v1/workspaces/\(c.workspaceId)" + path
        return components.url
    }
    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func manifestCanonicalFields(_ m: Manifest) -> [String] {
        [String(m.v), String(m.protocolVersion), m.workspaceId, m.deviceId, m.macDeviceId, m.transferId, m.recordingId,
            m.audioSHA256, String(m.plaintextLength), String(m.chunkSize), String(m.chunkCount)]
    }
    private enum TransferError: Error { case invalidCredentials, invalidManifest, invalidChunk, audioHashMismatch, emptyTranscript, invalidStoredReceipt, transcriptNotDurable, sessionNotDurable, macAudioCleanupFailed, requestFailed }
}
