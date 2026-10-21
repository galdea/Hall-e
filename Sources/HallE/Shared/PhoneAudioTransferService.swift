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

    /// Verifies the complete local proof chain before repairing an old
    /// premature-receipt cleanup: signed manifest, current audio bytes, and a
    /// signed receipt bound to the current meaningful transcript.
    static func validatesLocalCleanupProof(manifestCanonical: String, manifestMAC: String,
                                           receipt: [String: Any], eventDedupKey: String,
                                           sharedSessionID: String?, workspaceID: String,
                                           macDeviceID: String, libraryAudio: Data?,
                                           transferAudio: Data?, transcriptBytes: Data,
                                           transcriptText: String, key: Data) -> Bool {
        guard key.count == 32, isMeaningfulTranscript(transcriptText),
              manifestCanonical.utf8.count <= 2048, transcriptBytes.count <= 8 * 1024 * 1024,
              eventDedupKey.hasPrefix("phone-transfer:"), let transferID = UUID(uuidString: String(eventDedupKey.dropFirst("phone-transfer:".count))),
              let sharedSessionID, UUID(uuidString: sharedSessionID) != nil else { return false }
        let lines = manifestCanonical.components(separatedBy: "\n")
        guard lines.count == 12, lines.first == "halle-phone-audio-manifest-v1" else { return false }
        let fields = Array(lines.dropFirst())
        guard fields.count == 11, fields[0] == "1", fields[1] == "1",
              fields[2] == workspaceID, fields[4] == macDeviceID, fields[5] == transferID.uuidString.lowercased(),
              fields[6] == sharedSessionID.lowercased(), UUID(uuidString: fields[3]) != nil,
              fields[7].range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let plaintextLength = Int(fields[8]), (1...100 * 1024 * 1024).contains(plaintextLength),
              fields[9] == "262144", let chunkCount = Int(fields[10]),
              chunkCount == (plaintextLength + 262_143) / 262_144,
              manifestMAC == SharedMeetingCrypto.urlEncode(PhoneAudioTransferCrypto.manifestMAC(key: key, canonical: manifestCanonical)),
              libraryAudio != nil || transferAudio != nil,
              libraryAudio.map({ $0.count == plaintextLength && sha256Hex($0) == fields[7] }) ?? true,
              transferAudio.map({ $0.count == plaintextLength && sha256Hex($0) == fields[7] }) ?? true else { return false }
        let receiptFields = [fields[0], fields[1], fields[5], fields[2], fields[3], fields[4], fields[6],
                             fields[7], fields[8], fields[9], fields[10]]
        return storedReceiptMatches(receipt, fields: receiptFields,
                                    transcriptHash: sha256Hex(transcriptBytes), key: key)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum TransferCryptoError: Error { case invalidChunk }
}

enum PhoneAudioTransferRetryPolicy {
    /// This admits exactly the legacy completed-empty state. Once a retry is
    /// queued, its job status changes, so a later poll cannot queue it again.
    static func shouldRetryCompletedEmptyTranscript(jobStatus: TranscriptionJobStatus,
                                                    sessionStatus: TranscriptStatus,
                                                    transcript: Transcript?,
                                                    hasBothAudioCopies: Bool,
                                                    receiptExists: Bool) -> Bool {
        jobStatus == .completed && sessionStatus == .completed &&
            transcript?.status == .completed &&
            transcript.map { !PhoneAudioTransferCrypto.isMeaningfulTranscript($0.plainText) } == true &&
            hasBothAudioCopies && !receiptExists
    }
}

enum PhoneAudioTransferCleanup {
    struct FileFingerprint: Equatable, Sendable {
        let size: Int64
        let modificationTime: TimeInterval
        let systemNumber: UInt64?
        let fileNumber: UInt64?
    }

    struct Proof: Sendable {
        let sessionID: UUID
        let eventDedupKey: String
        let sharedSessionID: String
        let relativeFolder: String
        let libraryAudioURL: URL
        let transferAudioURL: URL
        let manifestURL: URL
        let receiptURL: URL
        let transcriptURL: URL
        let libraryAudio: FileFingerprint?
        let transferAudio: FileFingerprint?
        let manifest: FileFingerprint
        let receipt: FileFingerprint
        let transcript: FileFingerprint
    }

    static func libraryAudioURL(for session: RecordingSession,
                                recordingsRoot: URL = AppPaths.recordingsDir) -> URL {
        libraryAudioURL(relativeFolder: session.folderPath ?? session.slug, recordingsRoot: recordingsRoot)
    }

    static func libraryAudioURL(relativeFolder: String, recordingsRoot: URL) -> URL {
        var folder = recordingsRoot
        for part in relativeFolder.split(separator: "/") where part != "." && part != ".." {
            folder.appendPathComponent(String(part))
        }
        return folder.appendingPathComponent("phone.m4a")
    }

    static func transferAudioURL(transferID: String,
                                 transfersRoot: URL = AppPaths.appSupport
                                    .appendingPathComponent("PhoneTransfers", isDirectory: true)) -> URL {
        transfersRoot.appendingPathComponent(transferID + ".m4a")
    }

    /// Removes audio from the session's current folder, which can differ from
    /// the path captured before transcript-based filing moved the recording.
    static func purgeAudio(session: RecordingSession, transferAudioURL: URL,
                           recordingsRoot: URL = AppPaths.recordingsDir) throws {
        let libraryAudio = libraryAudioURL(for: session, recordingsRoot: recordingsRoot)
        if FileManager.default.fileExists(atPath: transferAudioURL.path) {
            try FileManager.default.removeItem(at: transferAudioURL)
        }
        if FileManager.default.fileExists(atPath: libraryAudio.path) {
            try FileManager.default.removeItem(at: libraryAudio)
        }
        guard !FileManager.default.fileExists(atPath: libraryAudio.path),
              !FileManager.default.fileExists(atPath: transferAudioURL.path) else {
            throw AudioCleanupError.filesRemain
        }
    }

    /// Reconciles only already-completed phone transfers with a fully valid
    /// local proof chain. Every file is size-bounded before it is read.
    static func prepareProof(eventDedupKey: String, sharedSessionID: String?, sessionID: UUID,
                             relativeFolder: String, workspaceID: String, macDeviceID: String, key: Data,
                             recordingsRoot: URL = AppPaths.recordingsDir,
                             transfersRoot: URL = AppPaths.appSupport
                                .appendingPathComponent("PhoneTransfers", isDirectory: true)) -> Proof? {
        guard key.count == 32, eventDedupKey.hasPrefix("phone-transfer:"),
              let sharedSessionID, UUID(uuidString: sharedSessionID) != nil else { return nil }
        let transferID = String(eventDedupKey.dropFirst("phone-transfer:".count))
        guard UUID(uuidString: transferID) != nil else { return nil }
        let manifestURL = transfersRoot.appendingPathComponent(transferID + ".manifest.json")
        let receiptURL = transfersRoot.appendingPathComponent(transferID + ".receipt.json")
        let partialURL = transferAudioURL(transferID: transferID, transfersRoot: transfersRoot)
        let audioURL = libraryAudioURL(relativeFolder: relativeFolder, recordingsRoot: recordingsRoot)
        let transcriptURL = audioURL.deletingLastPathComponent().appendingPathComponent("transcript.json")
        guard let (manifestBytes, manifestStamp) = stableData(at: manifestURL, maximum: 4096),
              let (receiptBytes, receiptStamp) = stableData(at: receiptURL, maximum: 16 * 1024),
              let (transcriptBytes, transcriptStamp) = stableData(at: transcriptURL, maximum: 8 * 1024 * 1024),
              let (libraryBytes, libraryStamp) = stableOptionalData(at: audioURL, maximum: 100 * 1024 * 1024),
              let (partialBytes, partialStamp) = stableOptionalData(at: partialURL, maximum: 100 * 1024 * 1024),
              libraryBytes != nil || partialBytes != nil,
              let manifest = try? JSONDecoder().decode(StoredManifest.self, from: manifestBytes),
              let receipt = try? JSONSerialization.jsonObject(with: receiptBytes) as? [String: Any],
              let transcript = try? JSONDecoder().decode(Transcript.self, from: transcriptBytes),
              transcript.status == .completed, transcript.sessionID == sessionID else { return nil }
        guard PhoneAudioTransferCrypto.validatesLocalCleanupProof(
            manifestCanonical: manifest.canonical, manifestMAC: manifest.mac, receipt: receipt,
            eventDedupKey: eventDedupKey, sharedSessionID: sharedSessionID,
            workspaceID: workspaceID, macDeviceID: macDeviceID, libraryAudio: libraryBytes,
            transferAudio: partialBytes, transcriptBytes: transcriptBytes,
            transcriptText: transcript.plainText, key: key) else { return nil }
        return Proof(sessionID: sessionID, eventDedupKey: eventDedupKey,
            sharedSessionID: sharedSessionID, relativeFolder: relativeFolder,
            libraryAudioURL: audioURL, transferAudioURL: partialURL,
            manifestURL: manifestURL, receiptURL: receiptURL, transcriptURL: transcriptURL,
            libraryAudio: libraryStamp, transferAudio: partialStamp,
            manifest: manifestStamp, receipt: receiptStamp, transcript: transcriptStamp)
    }

    /// Applies a background-verified proof only if the same session still
    /// points at the same folder and none of its source files changed.
    static func apply(_ proof: Proof, to session: RecordingSession,
                      recordingsRoot: URL = AppPaths.recordingsDir) -> Bool {
        guard session.id == proof.sessionID, session.eventDedupKey == proof.eventDedupKey,
              session.sharedSessionID == proof.sharedSessionID,
              (session.folderPath ?? session.slug) == proof.relativeFolder,
              session.transcriptStatus == .completed,
              (session.transcriptionJob ?? .legacy(status: session.transcriptStatus)).status == .completed,
              libraryAudioURL(for: session, recordingsRoot: recordingsRoot) == proof.libraryAudioURL,
              fingerprintsStillMatch(proof) else { return false }
        do {
            // Remove a matching staging copy first. The durable library copy
            // is the final deletion, so a failure leaves recoverable audio.
            if proof.transferAudio != nil { try FileManager.default.removeItem(at: proof.transferAudioURL) }
            guard !FileManager.default.fileExists(atPath: proof.transferAudioURL.path) else { return false }
            if proof.libraryAudio != nil { try FileManager.default.removeItem(at: proof.libraryAudioURL) }
            return !FileManager.default.fileExists(atPath: proof.libraryAudioURL.path) &&
                !FileManager.default.fileExists(atPath: proof.transferAudioURL.path)
        } catch {
            return false
        }
    }

    /// Synchronous wrapper for isolated temporary-file tests. Runtime calls
    /// `prepareProof` on a utility task, then applies it after MainActor checks.
    static func reconcileStoredReceiptAudio(session: RecordingSession, workspaceID: String,
                                            macDeviceID: String, key: Data,
                                            recordingsRoot: URL = AppPaths.recordingsDir,
                                            transfersRoot: URL = AppPaths.appSupport
                                                .appendingPathComponent("PhoneTransfers", isDirectory: true)) -> Bool {
        guard session.transcriptStatus == .completed,
              (session.transcriptionJob ?? .legacy(status: session.transcriptStatus)).status == .completed,
              let proof = prepareProof(eventDedupKey: session.eventDedupKey,
                sharedSessionID: session.sharedSessionID, sessionID: session.id,
                relativeFolder: session.folderPath ?? session.slug, workspaceID: workspaceID,
                macDeviceID: macDeviceID, key: key, recordingsRoot: recordingsRoot,
                transfersRoot: transfersRoot) else { return false }
        return apply(proof, to: session, recordingsRoot: recordingsRoot)
    }

    private static func stableData(at url: URL, maximum: Int) -> (Data, FileFingerprint)? {
        guard let before = fingerprint(at: url), before.size >= 0,
              before.size <= Int64(maximum),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              Int64(data.count) == before.size,
              fingerprint(at: url) == before else { return nil }
        return (data, before)
    }

    private static func stableOptionalData(at url: URL, maximum: Int) -> (Data?, FileFingerprint?)? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FileManager.default.fileExists(atPath: url.path) ? nil : (nil, nil)
        }
        guard let (data, stamp) = stableData(at: url, maximum: maximum) else { return nil }
        return (data, stamp)
    }

    private static func fingerprint(at url: URL) -> FileFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileFingerprint(size: size.int64Value, modificationTime: modified.timeIntervalSince1970,
            systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private static func fingerprintsStillMatch(_ proof: Proof) -> Bool {
        fingerprint(at: proof.manifestURL) == proof.manifest &&
            fingerprint(at: proof.receiptURL) == proof.receipt &&
            fingerprint(at: proof.transcriptURL) == proof.transcript &&
            fingerprint(at: proof.libraryAudioURL) == proof.libraryAudio &&
            fingerprint(at: proof.transferAudioURL) == proof.transferAudio
    }

    private struct StoredManifest: Decodable {
        let canonical: String
        let mac: String
    }

    enum AudioCleanupError: Error { case filesRemain }
}

/// Receives explicitly queued phone audio, transcribes it on this Mac, and
/// publishes a deletion receipt only after transcript.json survives readback.
@MainActor
final class PhoneAudioTransferService {
    static let shared = PhoneAudioTransferService()
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var cleanupCursor = 0
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
            await reconcilePriorReceipts(config: c)
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

    private func reconcilePriorReceipts(config c: PhoneAudioTransferCredentials) async {
        guard let key = SharedMeetingCrypto.urlDecode(c.key), key.count == 32 else { return }
        let candidates = RecordingStore.allSessions().filter {
            guard $0.eventDedupKey.hasPrefix("phone-transfer:"),
                  $0.transcriptStatus == .completed,
                  ($0.transcriptionJob ?? .legacy(status: $0.transcriptStatus)).status == .completed else { return false }
            let transferID = String($0.eventDedupKey.dropFirst("phone-transfer:".count))
            guard UUID(uuidString: transferID) != nil else { return false }
            return FileManager.default.fileExists(atPath: PhoneAudioTransferCleanup.libraryAudioURL(for: $0).path) ||
                FileManager.default.fileExists(atPath: PhoneAudioTransferCleanup.transferAudioURL(transferID: transferID).path)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard !candidates.isEmpty else { cleanupCursor = 0; return }
        // Rotate a small batch so an invalid old receipt cannot starve later
        // recoverable transfers, or hash a whole audio library on one UI turn.
        let start = cleanupCursor % candidates.count
        let batchCount = min(3, candidates.count)
        cleanupCursor = (start + batchCount) % candidates.count
        for offset in 0..<batchCount {
            guard !Task.isCancelled else { return }
            let candidate = candidates[(start + offset) % candidates.count]
            guard !RecordingCoordinator.isProcessing(sessionID: candidate.id) else { continue }
            let eventDedupKey = candidate.eventDedupKey
            let sharedSessionID = candidate.sharedSessionID
            let sessionID = candidate.id
            let relativeFolder = candidate.folderPath ?? candidate.slug
            let workspaceID = c.workspaceId
            let macDeviceID = c.deviceId
            let recordingsRoot = AppPaths.recordingsDir
            let transfersRoot = AppPaths.appSupport.appendingPathComponent("PhoneTransfers", isDirectory: true)
            let proof = await Task.detached(priority: .utility) {
                PhoneAudioTransferCleanup.prepareProof(eventDedupKey: eventDedupKey,
                    sharedSessionID: sharedSessionID, sessionID: sessionID,
                    relativeFolder: relativeFolder, workspaceID: workspaceID,
                    macDeviceID: macDeviceID, key: key, recordingsRoot: recordingsRoot,
                    transfersRoot: transfersRoot)
            }.value
            guard !Task.isCancelled else { return }
            guard let proof,
                  let latest = RecordingStore.allSessions().first(where: { $0.id == candidate.id }),
                  !RecordingCoordinator.isProcessing(sessionID: latest.id) else { continue }
            let cleaned = PhoneAudioTransferCleanup.apply(proof, to: latest)
            releasePlaybackIfAudioWasRemoved(latest)
            if cleaned {
                NotificationCenter.default.post(name: .halleRecordingChanged, object: nil)
                Log.rec.info("reconciled completed phone transfer audio cleanup: \(latest.id.uuidString, privacy: .public)")
            }
        }
    }

    private func releasePlaybackIfAudioWasRemoved(_ recording: RecordingSession) {
        let playback = RecordingPlaybackService.shared
        guard playback.activeSessionID == recording.id,
              !FileManager.default.fileExists(atPath: recording.playbackURL.path) else { return }
        playback.stop()
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
        let receiptFile = partialRoot.appendingPathComponent(m.transferId + ".receipt.json")
        let existingTranscript = TranscriptStore.load(sessionRecord)
        let jobStatus = (sessionRecord.transcriptionJob ?? .legacy(status: sessionRecord.transcriptStatus)).status
        let hasBothAudioCopies = hasAudioBytes(at: partial) &&
            hasAudioBytes(at: PhoneAudioTransferCleanup.libraryAudioURL(for: sessionRecord))
        if PhoneAudioTransferRetryPolicy.shouldRetryCompletedEmptyTranscript(
            jobStatus: jobStatus, sessionStatus: sessionRecord.transcriptStatus,
            transcript: existingTranscript, hasBothAudioCopies: hasBothAudioCopies,
            receiptExists: FileManager.default.fileExists(atPath: receiptFile.path)) {
            guard !RecordingCoordinator.isProcessing(sessionID: sessionRecord.id) else { return }
            // The coordinator preserves transcript.json until a replacement
            // succeeds. The queued job status prevents another retry on poll.
            RecordingCoordinator.retranscribe(session: sessionRecord)
            return
        }
        if jobStatus == .queued || existingTranscript?.status != .completed {
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
        do {
            try PhoneAudioTransferCleanup.purgeAudio(session: librarySession, transferAudioURL: partial)
        } catch {
            releasePlaybackIfAudioWasRemoved(librarySession)
            throw TransferError.macAudioCleanupFailed
        }
        releasePlaybackIfAudioWasRemoved(librarySession)
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
    private func hasAudioBytes(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.intValue > 0
    }
    private func manifestCanonicalFields(_ m: Manifest) -> [String] {
        [String(m.v), String(m.protocolVersion), m.workspaceId, m.deviceId, m.macDeviceId, m.transferId, m.recordingId,
            m.audioSHA256, String(m.plaintextLength), String(m.chunkSize), String(m.chunkCount)]
    }
    private enum TransferError: Error { case invalidCredentials, invalidManifest, invalidChunk, audioHashMismatch, emptyTranscript, invalidStoredReceipt, transcriptNotDurable, sessionNotDurable, macAudioCleanupFailed, requestFailed }
}
