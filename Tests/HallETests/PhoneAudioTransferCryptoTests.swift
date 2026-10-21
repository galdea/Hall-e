import Foundation
import Testing
@testable import HallE

struct PhoneAudioTransferCryptoTests {
    @Test func phoneTransferCredentialsAreValidatedBeforeUse() throws {
        let good: [String: Any] = [
            "endpoint": SharedMeetingCoordinator.endpoint,
            "workspaceId": "10000000-0000-4000-8000-000000000001",
            "deviceId": "20000000-0000-4000-8000-000000000001",
            "deviceToken": String(repeating: "a", count: 48),
            "key": SharedMeetingCrypto.urlEncode(Data(repeating: 1, count: 32)),
            "owner": true
        ]
        let goodData = try JSONSerialization.data(withJSONObject: good)
        let goodRaw = String(decoding: goodData, as: UTF8.self)
        #expect(PhoneAudioTransferCredentials.validated(goodRaw) != nil)

        var invalid = good
        invalid["endpoint"] = "https://attacker.example"
        #expect(PhoneAudioTransferCredentials.validated(String(decoding: try JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)) == nil)
        invalid = good; invalid["workspaceId"] = "not-a-uuid"
        #expect(PhoneAudioTransferCredentials.validated(String(decoding: try JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)) == nil)
        invalid = good; invalid["deviceToken"] = "short"
        #expect(PhoneAudioTransferCredentials.validated(String(decoding: try JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)) == nil)
        invalid = good; invalid["key"] = "not-a-32-byte-key"
        #expect(PhoneAudioTransferCredentials.validated(String(decoding: try JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)) == nil)
    }

    @Test func sharedPhoneMacCryptoKnownVector() throws {
        let key = Data(repeating: 1, count: 32)
        let fields = [
            "1", "1",
            "10000000-0000-4000-8000-000000000001",
            "20000000-0000-4000-8000-000000000001",
            "30000000-0000-4000-8000-000000000001",
            "40000000-0000-4000-8000-000000000001",
            "50000000-0000-4000-8000-000000000001",
            String(repeating: "a", count: 64), "3", "262144", "1"
        ]

        #expect(PhoneAudioTransferCrypto.deriveKey(key, purpose: "audio-encryption").hex ==
            "9bda2e3cdc3810ba70d652d670aea1e14bdd5446e27d66bce1630454f96e4244")
        #expect(PhoneAudioTransferCrypto.chunkAAD(fields: fields, index: 0).utf8String ==
            "halle-phone-audio-v1\n1\n1\n10000000-0000-4000-8000-000000000001\n" +
            "20000000-0000-4000-8000-000000000001\n30000000-0000-4000-8000-000000000001\n" +
            "40000000-0000-4000-8000-000000000001\n50000000-0000-4000-8000-000000000001\n" +
            "\(String(repeating: "a", count: 64))\n3\n262144\n1\n0")

        let encrypted = Data(hex: "44f5771563d0c1f51c5359243f95605eba95f24915098a600cabbed9325cc7")
        #expect(try PhoneAudioTransferCrypto.decryptChunk(encrypted, key: key, fields: fields, index: 0) == Data("abc".utf8))

        let canonical = "halle-phone-audio-receipt-v1\n1\n1\n" +
            "40000000-0000-4000-8000-000000000001\n" +
            "10000000-0000-4000-8000-000000000001\n" +
            "20000000-0000-4000-8000-000000000001\n" +
            "30000000-0000-4000-8000-000000000001\n" +
            "50000000-0000-4000-8000-000000000001\n" +
            "\(String(repeating: "a", count: 64))\n3\n262144\n1\n" +
            "\(String(repeating: "b", count: 64))\ntrue\n1700000000000"
        #expect(PhoneAudioTransferCrypto.receiptMAC(key: key, canonical: canonical).base64URLEncoded ==
            "0OmdHJEiKJOnUvDTDe3U24_60X48OtuCiRufSX2Jfd8")
    }

    @Test func emptyTranscriptCannotAuthorizePhoneAudioReceipt() {
        #expect(!PhoneAudioTransferCrypto.isMeaningfulTranscript(""))
        #expect(!PhoneAudioTransferCrypto.isMeaningfulTranscript(" \n\t \r\n"))
        #expect(PhoneAudioTransferCrypto.isMeaningfulTranscript("spoken words"))
    }

    @Test func completedEmptyTransferRetryIsOneShotAndRequiresAudioWithoutReceipt() {
        let empty = Transcript(sessionID: UUID(), localeUsed: "en-US", segments: [],
                               status: .completed, source: "sfspeech-on-device")
        func shouldRetry(job: TranscriptionJobStatus = .completed, session: TranscriptStatus = .completed,
                         transcript: Transcript? = nil, audio: Bool = true, receipt: Bool = false) -> Bool {
            PhoneAudioTransferRetryPolicy.shouldRetryCompletedEmptyTranscript(
                jobStatus: job, sessionStatus: session, transcript: transcript,
                hasBothAudioCopies: audio, receiptExists: receipt)
        }

        #expect(shouldRetry(transcript: empty))
        #expect(!shouldRetry(job: .queued)) // The retry has been consumed.
        #expect(!shouldRetry(job: .retryableFailed)) // A blank retry is never polled again.
        #expect(!shouldRetry(audio: false))
        #expect(!shouldRetry(receipt: true))
        let meaningful = Transcript(sessionID: UUID(), localeUsed: "en-US",
            segments: [TranscriptSegment(start: 0, duration: 1, text: "Hello", track: "system")],
            status: .completed, source: "sfspeech-on-device")
        #expect(!shouldRetry(transcript: meaningful))
        #expect(!shouldRetry(session: .failed))
    }

    @Test func storedReceiptMustBindCurrentTranscriptAndManifest() throws {
        let key = Data(repeating: 1, count: 32)
        let fields = ["1", "1", "40000000-0000-4000-8000-000000000001",
            "10000000-0000-4000-8000-000000000001", "20000000-0000-4000-8000-000000000001",
            "30000000-0000-4000-8000-000000000001", "50000000-0000-4000-8000-000000000001",
            String(repeating: "a", count: 64), "3", "262144", "1"]
        let transcriptHash = String(repeating: "b", count: 64)
        let savedAtMs = 1_700_000_000_000
        let canonical = "halle-phone-audio-receipt-v1\n" +
            (Array(fields.prefix(11)) + [transcriptHash, "true", String(savedAtMs)]).joined(separator: "\n")
        let receipt: [String: Any] = ["v": 1, "protocolVersion": 1, "transferId": fields[2],
            "workspaceId": fields[3], "deviceId": fields[4], "macDeviceId": fields[5], "recordingId": fields[6],
            "audioSHA256": fields[7], "plaintextLength": 3, "chunkSize": 262_144, "chunkCount": 1,
            "transcriptSHA256": transcriptHash, "macAudioPurged": true, "savedAtMs": savedAtMs,
            "mac": PhoneAudioTransferCrypto.receiptMAC(key: key, canonical: canonical).base64URLEncoded]
        #expect(PhoneAudioTransferCrypto.storedReceiptMatches(receipt, fields: fields, transcriptHash: transcriptHash, key: key))
        #expect(!PhoneAudioTransferCrypto.storedReceiptMatches(receipt, fields: fields,
            transcriptHash: String(repeating: "c", count: 64), key: key))
        var stale = receipt
        stale["recordingId"] = "different-recording"
        #expect(!PhoneAudioTransferCrypto.storedReceiptMatches(stale, fields: fields, transcriptHash: transcriptHash, key: key))
        stale = receipt; stale["macAudioPurged"] = false
        #expect(!PhoneAudioTransferCrypto.storedReceiptMatches(stale, fields: fields, transcriptHash: transcriptHash, key: key))
    }

    @Test func transferCleanupUsesSessionFolderAfterTranscriptFilingMovesIt() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("halle-phone-transfer-cleanup-\(UUID().uuidString)", isDirectory: true)
        let recordingsRoot = temporaryRoot.appendingPathComponent("Recordings", isDirectory: true)
        let transferAudio = temporaryRoot.appendingPathComponent("transfer.m4a")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let event = UnifiedEvent(dedupKey: "phone-transfer:test-transfer", title: "Reunión instantánea",
            startTs: Date(timeIntervalSince1970: 1_792_540_000), endTs: Date(timeIntervalSince1970: 1_792_540_060),
            isAllDay: false, status: "confirmed", effectiveResponse: nil, meetingURL: nil, location: nil,
            descriptionText: nil, htmlLink: nil, organizerEmail: nil, attendeesJSON: nil, iCalUID: nil,
            winnerAccountEmail: "", projectId: nil, projectConfidence: nil, sourcesJSON: "[]")
        var session = RecordingSession(event: event, notePath: nil, sourceKind: .manual)
        session.playbackFileName = "phone.m4a"
        session.folderPath = "Unclassified/\(session.slug)"
        let originalFolder = recordingsRoot.appendingPathComponent(session.folderPath!)
        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: originalFolder.appendingPathComponent("session.json"))
        try Data("library audio".utf8).write(to: originalFolder.appendingPathComponent("phone.m4a"))
        try Data("transfer audio".utf8).write(to: transferAudio)

        // Successful transcription files the session into a descriptive folder.
        let movedRelativePath = "Unclassified/2026-10-20 2054 - Reunión instantánea"
        let movedFolder = recordingsRoot.appendingPathComponent(movedRelativePath)
        try FileManager.default.createDirectory(at: movedFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: originalFolder, to: movedFolder)
        session.folderPath = movedRelativePath
        try JSONEncoder().encode(session).write(to: movedFolder.appendingPathComponent("session.json"), options: .atomic)

        let currentSession = try #require(RecordingStore.sessions(in: recordingsRoot)
            .first(where: { $0.eventDedupKey == event.dedupKey }))
        let renamedLibraryAudio = PhoneAudioTransferCleanup.libraryAudioURL(for: currentSession,
                                                                            recordingsRoot: recordingsRoot)
        #expect(renamedLibraryAudio.path == movedFolder.appendingPathComponent("phone.m4a").path)
        #expect(FileManager.default.fileExists(atPath: renamedLibraryAudio.path))

        try PhoneAudioTransferCleanup.purgeAudio(session: currentSession, transferAudioURL: transferAudio,
                                                 recordingsRoot: recordingsRoot)

        #expect(!FileManager.default.fileExists(atPath: renamedLibraryAudio.path))
        #expect(!FileManager.default.fileExists(atPath: transferAudio.path))
    }
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        })
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
    var utf8String: String { String(decoding: self, as: UTF8.self) }
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
