import Foundation
import Testing
@testable import HallE

private actor CredentialReaderGate {
    private var isReading = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<String?, Error>?

    func read() async throws -> String? {
        isReading = true
        enteredContinuation?.resume()
        return try await withCheckedThrowingContinuation { resultContinuation = $0 }
    }

    func waitUntilReading() async {
        guard !isReading else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func finish(_ result: String?) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

@Suite struct SharedMeetingTests {
    private let sessionID = "47f13ed1-11e1-4fb7-9c88-158084e94a4a"

    @MainActor @Test func localCaptureWaitsForLazyCredentialReadBeforeAllowingUnpairedUse() async throws {
        let gate = CredentialReaderGate()
        let coordinator = SharedMeetingCoordinator(credentialReader: { try await gate.read() })
        #expect(coordinator.credentialsLoadState == .loading)

        let capture = Task {
            try await coordinator.prepareLocalCapture(event: Self.event(), requestedSessionID: nil)
        }
        await gate.waitUntilReading()
        await gate.finish(nil)

        #expect(try await capture.value == nil)
        #expect(coordinator.credentialsLoadState == .unpaired)
    }

    @MainActor @Test func deniedCredentialReadCannotFallThroughToUnpairedLocalCapture() async {
        let coordinator = SharedMeetingCoordinator(credentialReader: {
            throw TestCredentialReadDenied()
        })

        await #expect(throws: SharedMeetingError.self) {
            try await coordinator.prepareLocalCapture(event: Self.event(), requestedSessionID: nil)
        }
        #expect(coordinator.credentialsLoadState == .failed(TestCredentialReadDenied().localizedDescription))
    }

    private struct TestCredentialReadDenied: Error, LocalizedError {
        var errorDescription: String? { "Keychain access denied for test" }
    }

    private static func event() -> UnifiedEvent {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return UnifiedEvent(dedupKey: "event", title: "Get Accurate", startTs: start,
                            endTs: start.addingTimeInterval(600), isAllDay: false,
                            status: "confirmed", effectiveResponse: nil, meetingURL: nil,
                            location: nil, descriptionText: nil, htmlLink: nil,
                            organizerEmail: nil, attendeesJSON: nil, iCalUID: nil,
                            winnerAccountEmail: "a@example.com", projectId: nil,
                            projectConfidence: nil, sourcesJSON: "[]")
    }

    @Test func leaseDeadlineUsesRequestStartMonotonicTimeAndRejectsLateRenewal() {
        var deadline = SharedLeaseDeadline()
        #expect(!deadline.isValid(at: 10))
        let initialGrant = deadline.grant(requestStarted: 10, receivedAt: 11)
        #expect(initialGrant)
        #expect(deadline.isValid(at: 24.999))
        #expect(!deadline.isValid(at: 25))

        // A response received at the proposed deadline is too late and cannot revive capture.
        let lateGrant = deadline.grant(requestStarted: 20, receivedAt: 35)
        #expect(!lateGrant)
        #expect(!deadline.isValid(at: 25))
        deadline.invalidate()
        #expect(!deadline.isValid(at: 11))
    }

    @Test func aesGCMCombinedWireFormatRoundTripsAndAuthenticatesSessionAndKey() throws {
        let key = Data(repeating: 0, count: 32)
        let plaintext = Data("shared-session-vector".utf8)

        // A fixed AES-256-GCM wire vector with 12-byte nonce, UTF-8 AAD, and 16-byte tag.
        // Android uses nonce || Cipher.doFinal() (ciphertext || tag), matching CryptoKit's combined form.
        let androidCompatibleVector = "AAAAAAAAAAAAAAAAvc8hTygERh1iPba61Z2wbhcDd6VFxgi25C2u/QhM7kfVT5Mz6A=="
        #expect(try SharedMeetingCrypto.decrypt(androidCompatibleVector, key: key, sessionID: sessionID) == plaintext)

        let encrypted = try SharedMeetingCrypto.encrypt(plaintext, key: key, sessionID: sessionID)
        let packed = try #require(Data(base64Encoded: encrypted))
        #expect(packed.count == 12 + plaintext.count + 16)
        #expect(try SharedMeetingCrypto.decrypt(encrypted, key: key, sessionID: sessionID) == plaintext)
        #expect(throws: (any Error).self) {
            try SharedMeetingCrypto.decrypt(encrypted, key: key, sessionID: UUID().uuidString)
        }
        #expect(throws: (any Error).self) {
            try SharedMeetingCrypto.decrypt(encrypted, key: Data(repeating: 1, count: 32), sessionID: sessionID)
        }

        var tampered = packed
        tampered[tampered.count - 1] ^= 1
        #expect(throws: (any Error).self) {
            try SharedMeetingCrypto.decrypt(tampered.base64EncodedString(), key: key, sessionID: sessionID)
        }
    }

    @Test func invitationAcceptsOnlyTheAllowlistedPageAndCoordinator() throws {
        #expect(SharedMeetingCoordinator.endpoint == "https://halle-shared-session-coordinator.gabriel-aldea.workers.dev")
        let value: [String: Any] = [
            "v": 1,
            "endpoint": SharedMeetingCoordinator.endpoint,
            "workspaceId": sessionID,
            "inviteToken": String(repeating: "i", count: 43),
            "key": SharedMeetingCrypto.urlEncode(Data(repeating: 7, count: 32)),
        ]
        let code = SharedMeetingCrypto.urlEncode(try JSONSerialization.data(withJSONObject: value))
        let accepted = try SharedMeetingCoordinator.parseInvitation("https://hall-e.pages.dev/pair#\(code)")
        #expect(accepted["workspaceId"] as? String == sessionID)
        #expect(try SharedMeetingCoordinator.parseInvitation("halle://pair?payload=\(code)")["v"] as? Int == 1)

        for invalid in [
            "https://evil.example/pair#\(code)",
            "https://hall-e.pages.dev.attacker.test/pair#\(code)",
            "https://hall-e.pages.dev/other#\(code)",
            "halle://attacker?payload=\(code)",
        ] {
            #expect(throws: SharedMeetingError.self) {
                try SharedMeetingCoordinator.parseInvitation(invalid)
            }
        }

        var wrongEndpoint = value
        wrongEndpoint["endpoint"] = "https://attacker.test"
        let wrongEndpointCode = SharedMeetingCrypto.urlEncode(try JSONSerialization.data(withJSONObject: wrongEndpoint))
        #expect(throws: SharedMeetingError.self) {
            try SharedMeetingCoordinator.parseInvitation("https://hall-e.pages.dev/pair#\(wrongEndpointCode)")
        }
    }
}
