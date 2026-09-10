import Foundation
import Testing
@testable import HallE

@Suite("Cloud credential setup")
struct CloudCredentialValidationTests {
    private static func reply(_ request: URLRequest, status: Int = 200,
                              json: String = #"{"api_key_id":"fixture-id"}"#) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                        httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    @Test func checksUseReadOnlyEndpointsWithoutAudioOrSecretsInURL() throws {
        let deepgram = try CloudCredentialValidation.request(target: .deepgram, key: "  fixture-key\n")
        #expect(deepgram.httpMethod == "GET")
        #expect(deepgram.url?.absoluteString == "https://api.deepgram.com/v1/auth/token")
        #expect(deepgram.value(forHTTPHeaderField: "Authorization") == "Token fixture-key")
        #expect(deepgram.httpBody == nil)
        #expect(deepgram.httpBodyStream == nil)
        for region in SpeechmaticsRegion.supportedRegions {
            let request = try CloudCredentialValidation.request(target: .speechmatics(region), key: "fixture-key")
            #expect(request.httpMethod == "GET")
            #expect(request.url?.host == "\(region.rawValue).asr.api.speechmatics.com")
            #expect(request.url?.path == "/v2/jobs")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(request.httpBody == nil)
            #expect(request.url?.absoluteString.contains("fixture-key") == false)
        }
    }

    @Test(arguments: ["", " \n", "Bearer secret", "Token secret", "embedded\nnewline", "key\u{0000}"])
    func malformedKeysAreRejectedBeforeNetwork(key: String) async {
        await #expect(throws: CloudCredentialValidationError.invalidKey) {
            try await CloudCredentialValidation.validate(target: .deepgram, key: key, transport: { request in
                Issue.record("Invalid keys must never reach the transport")
                return Self.reply(request)
            })
        }
    }

    @Test func unsupportedRegionIsRejectedBeforeNetwork() async {
        await #expect(throws: CloudCredentialValidationError.unsupportedRegion) {
            try await CloudCredentialValidation.validate(target: .speechmatics(.au1), key: "fixture-key",
                                                         transport: { request in
                Issue.record("Unsupported regions must never reach the transport")
                return Self.reply(request)
            })
        }
    }

    @Test func successfulChecksAcceptEmptySpeechmaticsJobHistory() async throws {
        try await CloudCredentialValidation.validate(target: .deepgram, key: "fixture-key",
                                                     transport: { Self.reply($0) })
        try await CloudCredentialValidation.validate(target: .speechmatics(.eu1), key: "fixture-key",
                                                     transport: { Self.reply($0, json: #"{"jobs":[]}"#) })
    }

    @Test(arguments: [301, 401, 403, 429, 500])
    func nonSuccessHTTPResponsesAreRejected(status: Int) async {
        await #expect(throws: CloudCredentialValidationError.rejected(provider: "Deepgram", status: status)) {
            try await CloudCredentialValidation.validate(target: .deepgram, key: "fixture-key",
                                                         transport: { Self.reply($0, status: status) })
        }
    }

    @Test(arguments: ["{}", "[]", "not JSON", #"{"error":"denied"}"#, #"{"err_code":"INVALID_AUTH"}"#])
    func malformedSuccessBodiesAreRejected(json: String) async {
        await #expect(throws: CloudCredentialValidationError.invalidResponse(provider: "Deepgram")) {
            try await CloudCredentialValidation.validate(target: .deepgram, key: "fixture-key",
                                                         transport: { Self.reply($0, json: json) })
        }
    }

    @Test func speechmaticsRequiresAJobListResponse() async {
        await #expect(throws: CloudCredentialValidationError.invalidResponse(provider: "Speechmatics")) {
            try await CloudCredentialValidation.validate(target: .speechmatics(.us1), key: "fixture-key",
                                                         transport: { Self.reply($0) })
        }
    }

    @Test func transportErrorsAreSanitized() async {
        await #expect(throws: CloudCredentialValidationError.unavailable(provider: "Deepgram")) {
            try await CloudCredentialValidation.validate(target: .deepgram, key: "fixture-secret",
                                                         transport: { _ in
                throw NSError(domain: "fixture-secret", code: 1)
            })
        }
    }

    @MainActor @Test func rejectedReplacementPreservesWorkingKeyAndReceipt() async {
        let suite = "CloudCredentialTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored = "working-key"
        CloudCredentialValidation.recordSuccess(target: .deepgram, key: stored, defaults: defaults)
        await #expect(throws: CloudCredentialValidationError.rejected(provider: "Deepgram", status: 401)) {
            try await CloudCredentialValidation.checkAndSave(
                target: .deepgram, replacement: "bad-key", defaults: defaults,
                transport: { Self.reply($0, status: 401) }, readKey: { _ in stored },
                writeKey: { value, _ in stored = value })
        }
        #expect(stored == "working-key")
        #expect(CloudCredentialValidation.isVerified(target: .deepgram, key: stored, defaults: defaults))
    }

    @MainActor @Test func successfulReplacementIsTrimmedStoredAndVerified() async throws {
        let suite = "CloudCredentialTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored: String?
        try await CloudCredentialValidation.checkAndSave(
            target: .deepgram, replacement: " new-key\n", defaults: defaults,
            transport: { Self.reply($0) }, readKey: { _ in stored },
            writeKey: { value, account in
                #expect(account == KeychainStore.deepgramTranscriptionAccount)
                stored = value
            })
        #expect(stored == "new-key")
        #expect(CloudCredentialValidation.isVerified(target: .deepgram, key: stored, defaults: defaults))
        #expect(defaults.string(forKey: CloudCredentialTarget.deepgram.receiptKey) != stored)
    }

    @MainActor @Test func keychainWriteFailureCannotVerifyUnsavedReplacement() async {
        let suite = "CloudCredentialTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        await #expect(throws: CloudCredentialValidationError.keychainWriteFailed) {
            try await CloudCredentialValidation.checkAndSave(
                target: .deepgram, replacement: "new-key", defaults: defaults,
                transport: { Self.reply($0) }, readKey: { _ in "old-key" },
                writeKey: { _, _ in throw NSError(domain: "fixture-keychain", code: 1) })
        }
        #expect(!CloudCredentialValidation.isVerified(target: .deepgram, key: "new-key", defaults: defaults))
    }

    @MainActor @Test func concurrentKeyChangeIsNeverOverwritten() async {
        let suite = "CloudCredentialTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored = "old-key"
        await #expect(throws: CloudCredentialValidationError.credentialChanged) {
            try await CloudCredentialValidation.checkAndSave(
                target: .deepgram, replacement: "replacement", defaults: defaults,
                transport: { request in
                    stored = "changed-in-another-window"
                    return Self.reply(request)
                }, readKey: { _ in stored }, writeKey: { value, _ in stored = value })
        }
        #expect(stored == "changed-in-another-window")
        #expect(!CloudCredentialValidation.isVerified(target: .deepgram, key: stored, defaults: defaults))
    }

    @MainActor @Test func cancelledCheckCannotSaveAReplacement() async {
        let suite = "CloudCredentialTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored = "working-key"
        let check = Task { @MainActor in
            try await CloudCredentialValidation.checkAndSave(
                target: .deepgram, replacement: "new-key", defaults: defaults,
                transport: { request in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return Self.reply(request)
                }, readKey: { _ in stored }, writeKey: { value, _ in stored = value })
        }
        await #expect(throws: CancellationError.self) { try await check.value }
        #expect(stored == "working-key")
        #expect(!CloudCredentialValidation.isVerified(target: .deepgram, key: "new-key", defaults: defaults))
    }

    @Test func verificationIsBoundToTheKeyAndProcessingRegion() {
        let suite = "CloudCredentialTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        CloudCredentialValidation.recordSuccess(target: .speechmatics(.eu1), key: "fixture-key", defaults: defaults)
        #expect(CloudCredentialValidation.isVerified(target: .speechmatics(.eu1), key: "fixture-key", defaults: defaults))
        #expect(!CloudCredentialValidation.isVerified(target: .speechmatics(.us1), key: "fixture-key", defaults: defaults))
        #expect(!CloudCredentialValidation.isVerified(target: .speechmatics(.eu1), key: "changed-key", defaults: defaults))
        CloudCredentialValidation.invalidate(target: .speechmatics(.eu1), defaults: defaults)
        #expect(!CloudCredentialValidation.isVerified(target: .speechmatics(.eu1), key: "fixture-key", defaults: defaults))
    }
}
