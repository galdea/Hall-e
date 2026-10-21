import Foundation
import CryptoKit
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

    @Test func localReceiptReconciliationRequiresSignedCurrentArtifacts() throws {
        let key = Data(repeating: 7, count: 32)
        let workspace = "10000000-0000-4000-8000-000000000001"
        let phone = "20000000-0000-4000-8000-000000000001"
        let mac = "30000000-0000-4000-8000-000000000001"
        let transfer = "40000000-0000-4000-8000-000000000001"
        let recording = "50000000-0000-4000-8000-000000000001"
        let audioBytes = Data("verified phone audio".utf8)

        func makeFixture(transcriptText: String = "Verified spoken words",
                         partialBytes: Data? = nil,
                         tamperManifestMAC: Bool = false,
                         tamperReceiptMAC: Bool = false) throws -> (URL, URL, URL, RecordingSession) {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("halle-local-transfer-reconcile-\(UUID().uuidString)", isDirectory: true)
            let recordingsRoot = temporary.appendingPathComponent("Recordings", isDirectory: true)
            let transfersRoot = temporary.appendingPathComponent("PhoneTransfers", isDirectory: true)
            let folderPath = "Unclassified/2026-10-20 verified phone transfer"
            let folder = recordingsRoot.appendingPathComponent(folderPath)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: transfersRoot, withIntermediateDirectories: true)

            let event = UnifiedEvent(dedupKey: "phone-transfer:\(transfer)", title: "Verified phone transfer",
                startTs: Date(timeIntervalSince1970: 1_792_540_000), endTs: Date(timeIntervalSince1970: 1_792_540_060),
                isAllDay: false, status: "confirmed", effectiveResponse: nil, meetingURL: nil, location: nil,
                descriptionText: nil, htmlLink: nil, organizerEmail: nil, attendeesJSON: nil, iCalUID: nil,
                winnerAccountEmail: "", projectId: nil, projectConfidence: nil, sourcesJSON: "[]")
            var session = RecordingSession(event: event, notePath: nil, sourceKind: .manual)
            session.folderPath = folderPath
            session.playbackFileName = "phone.m4a"
            session.transcriptStatus = .completed
            session.transcriptionJob = TranscriptionJob(status: .completed)
            session.sharedSessionID = recording
            try JSONEncoder().encode(session).write(to: folder.appendingPathComponent("session.json"))
            try audioBytes.write(to: folder.appendingPathComponent("phone.m4a"))
            let transcript = Transcript(sessionID: session.id, localeUsed: "en-US",
                segments: transcriptText.isEmpty ? [] : [TranscriptSegment(start: 0, duration: 1,
                    text: transcriptText, track: "mic")], status: .completed, source: "sfspeech-on-device")
            let transcriptBytes = try JSONEncoder().encode(transcript)
            try transcriptBytes.write(to: folder.appendingPathComponent("transcript.json"))
            if let partialBytes {
                try partialBytes.write(to: transfersRoot.appendingPathComponent(transfer + ".m4a"))
            }

            let chunkSize = 262_144
            let manifestFields = ["1", "1", workspace, phone, mac, transfer, recording,
                Data(audioBytes).sha256Hex, String(audioBytes.count), String(chunkSize),
                String((audioBytes.count + chunkSize - 1) / chunkSize)]
            let manifestCanonical = "halle-phone-audio-manifest-v1\n" + manifestFields.joined(separator: "\n")
            var manifestMAC = PhoneAudioTransferCrypto.manifestMAC(key: key, canonical: manifestCanonical)
            if tamperManifestMAC { manifestMAC[manifestMAC.startIndex] ^= 1 }
            let signedManifest: [String: String] = ["canonical": manifestCanonical,
                "mac": SharedMeetingCrypto.urlEncode(manifestMAC)]
            try JSONSerialization.data(withJSONObject: signedManifest, options: [.sortedKeys])
                .write(to: transfersRoot.appendingPathComponent(transfer + ".manifest.json"))

            let receiptFields = ["1", "1", transfer, workspace, phone, mac, recording,
                manifestFields[7], manifestFields[8], manifestFields[9], manifestFields[10]]
            let savedAtMs = 1_792_540_000_000
            let transcriptHash = transcriptBytes.sha256Hex
            let canonical = "halle-phone-audio-receipt-v1\n" +
                (receiptFields + [transcriptHash, "true", String(savedAtMs)]).joined(separator: "\n")
            var receiptMAC = PhoneAudioTransferCrypto.receiptMAC(key: key, canonical: canonical)
            if tamperReceiptMAC { receiptMAC[receiptMAC.startIndex] ^= 1 }
            let receipt: [String: Any] = ["v": 1, "protocolVersion": 1, "transferId": transfer,
                "workspaceId": workspace, "deviceId": phone, "macDeviceId": mac, "recordingId": recording,
                "audioSHA256": manifestFields[7], "plaintextLength": audioBytes.count,
                "chunkSize": chunkSize, "chunkCount": 1, "transcriptSHA256": transcriptHash,
                "macAudioPurged": true, "savedAtMs": savedAtMs,
                "mac": receiptMAC.base64URLEncoded]
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                .write(to: transfersRoot.appendingPathComponent(transfer + ".receipt.json"))
            return (recordingsRoot, transfersRoot, temporary, session)
        }

        let valid = try makeFixture(partialBytes: audioBytes)
        defer { try? FileManager.default.removeItem(at: valid.2) }
        #expect(PhoneAudioTransferCleanup.reconcileStoredReceiptAudio(session: valid.3,
            workspaceID: workspace, macDeviceID: mac, key: key,
            recordingsRoot: valid.0, transfersRoot: valid.1))
        #expect(!FileManager.default.fileExists(atPath: valid.0.appendingPathComponent(valid.3.folderPath!)
            .appendingPathComponent("phone.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: valid.1.appendingPathComponent(transfer + ".m4a").path))

        let badSignature = try makeFixture(tamperManifestMAC: true)
        defer { try? FileManager.default.removeItem(at: badSignature.2) }
        #expect(!PhoneAudioTransferCleanup.reconcileStoredReceiptAudio(session: badSignature.3,
            workspaceID: workspace, macDeviceID: mac, key: key,
            recordingsRoot: badSignature.0, transfersRoot: badSignature.1))
        #expect(FileManager.default.fileExists(atPath: badSignature.0.appendingPathComponent(badSignature.3.folderPath!)
            .appendingPathComponent("phone.m4a").path))

        let badReceipt = try makeFixture(tamperReceiptMAC: true)
        defer { try? FileManager.default.removeItem(at: badReceipt.2) }
        #expect(!PhoneAudioTransferCleanup.reconcileStoredReceiptAudio(session: badReceipt.3,
            workspaceID: workspace, macDeviceID: mac, key: key,
            recordingsRoot: badReceipt.0, transfersRoot: badReceipt.1))
        #expect(FileManager.default.fileExists(atPath: badReceipt.0.appendingPathComponent(badReceipt.3.folderPath!)
            .appendingPathComponent("phone.m4a").path))

        let wrongWorkspace = try makeFixture()
        defer { try? FileManager.default.removeItem(at: wrongWorkspace.2) }
        #expect(!PhoneAudioTransferCleanup.reconcileStoredReceiptAudio(session: wrongWorkspace.3,
            workspaceID: "60000000-0000-4000-8000-000000000001", macDeviceID: mac, key: key,
            recordingsRoot: wrongWorkspace.0, transfersRoot: wrongWorkspace.1))
        #expect(FileManager.default.fileExists(atPath: wrongWorkspace.0.appendingPathComponent(wrongWorkspace.3.folderPath!)
            .appendingPathComponent("phone.m4a").path))

        let changedTranscript = try makeFixture()
        defer { try? FileManager.default.removeItem(at: changedTranscript.2) }
        let changed = Transcript(sessionID: changedTranscript.3.id, localeUsed: "en-US",
            segments: [TranscriptSegment(start: 0, duration: 1, text: "Edited after receipt", track: "mic")],
            status: .completed, source: "sfspeech-on-device")
        try JSONEncoder().encode(changed).write(to: changedTranscript.0
            .appendingPathComponent(changedTranscript.3.folderPath!).appendingPathComponent("transcript.json"), options: .atomic)
        #expect(!PhoneAudioTransferCleanup.reconcileStoredReceiptAudio(session: changedTranscript.3,
            workspaceID: workspace, macDeviceID: mac, key: key,
            recordingsRoot: changedTranscript.0, transfersRoot: changedTranscript.1))
        #expect(FileManager.default.fileExists(atPath: changedTranscript.0.appendingPathComponent(changedTranscript.3.folderPath!)
            .appendingPathComponent("phone.m4a").path))

        let blank = try makeFixture(transcriptText: " \n ")
        defer { try? FileManager.default.removeItem(at: blank.2) }
        #expect(!PhoneAudioTransferCleanup.reconcileStoredReceiptAudio(session: blank.3,
            workspaceID: workspace, macDeviceID: mac, key: key,
            recordingsRoot: blank.0, transfersRoot: blank.1))
        #expect(FileManager.default.fileExists(atPath: blank.0.appendingPathComponent(blank.3.folderPath!)
            .appendingPathComponent("phone.m4a").path))

        let mismatchedPartial = try makeFixture(partialBytes: Data("different bytes".utf8))
        defer { try? FileManager.default.removeItem(at: mismatchedPartial.2) }
        #expect(!PhoneAudioTransferCleanup.reconcileStoredReceiptAudio(session: mismatchedPartial.3,
            workspaceID: workspace, macDeviceID: mac, key: key,
            recordingsRoot: mismatchedPartial.0, transfersRoot: mismatchedPartial.1))
        #expect(FileManager.default.fileExists(atPath: mismatchedPartial.0.appendingPathComponent(mismatchedPartial.3.folderPath!)
            .appendingPathComponent("phone.m4a").path))

        let changedAfterProof = try makeFixture()
        defer { try? FileManager.default.removeItem(at: changedAfterProof.2) }
        let proof = try #require(PhoneAudioTransferCleanup.prepareProof(
            eventDedupKey: changedAfterProof.3.eventDedupKey,
            sharedSessionID: changedAfterProof.3.sharedSessionID, sessionID: changedAfterProof.3.id,
            relativeFolder: changedAfterProof.3.folderPath!, workspaceID: workspace, macDeviceID: mac,
            key: key, recordingsRoot: changedAfterProof.0, transfersRoot: changedAfterProof.1))
        let changedAudioURL = changedAfterProof.0.appendingPathComponent(changedAfterProof.3.folderPath!)
            .appendingPathComponent("phone.m4a")
        let changedAudio = try Data(contentsOf: changedAudioURL) + Data(" changed".utf8)
        try changedAudio.write(to: changedAudioURL, options: .atomic)
        #expect(!PhoneAudioTransferCleanup.apply(proof, to: changedAfterProof.3,
                                                 recordingsRoot: changedAfterProof.0))
        #expect(FileManager.default.fileExists(atPath: changedAudioURL.path))

        let stagingOnly = try makeFixture()
        defer { try? FileManager.default.removeItem(at: stagingOnly.2) }
        let libraryAudioURL = stagingOnly.0.appendingPathComponent(stagingOnly.3.folderPath!)
            .appendingPathComponent("phone.m4a")
        try FileManager.default.removeItem(at: libraryAudioURL)
        try audioBytes.write(to: stagingOnly.1.appendingPathComponent(transfer + ".m4a"))
        #expect(PhoneAudioTransferCleanup.reconcileStoredReceiptAudio(session: stagingOnly.3,
            workspaceID: workspace, macDeviceID: mac, key: key,
            recordingsRoot: stagingOnly.0, transfersRoot: stagingOnly.1))
        #expect(!FileManager.default.fileExists(atPath: stagingOnly.1.appendingPathComponent(transfer + ".m4a").path))
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
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
