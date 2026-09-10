import Foundation
import CryptoKit

/// Read-only authentication checks. No audio, transcription jobs, or balance
/// requests are sent. A successful check does not promise remaining credit.
enum CloudCredentialTarget: Equatable {
    case deepgram
    case speechmatics(SpeechmaticsRegion)

    var name: String {
        switch self {
        case .deepgram: return "Deepgram"
        case .speechmatics: return "Speechmatics"
        }
    }

    var account: String {
        switch self {
        case .deepgram: return KeychainStore.deepgramTranscriptionAccount
        case .speechmatics: return KeychainStore.speechmaticsTranscriptionAccount
        }
    }

    var receiptKey: String {
        switch self {
        case .deepgram: return "cloudKeyCheck.deepgram.v1"
        case .speechmatics(let region): return "cloudKeyCheck.speechmatics.\(region.rawValue).v1"
        }
    }
}

enum CloudCredentialValidationError: Error, LocalizedError, Equatable {
    case invalidKey
    case unsupportedRegion
    case rejected(provider: String, status: Int)
    case unavailable(provider: String)
    case invalidResponse(provider: String)
    case keychainWriteFailed
    case credentialChanged

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Paste the secret API key only, without spaces or an Authorization prefix."
        case .unsupportedRegion:
            return "Choose a supported Speechmatics processing region before testing the key."
        case .rejected(let provider, let status):
            if status == 401 || status == 403 {
                return "\(provider) rejected this key (HTTP \(status)). Check that it is active and has access to transcription. Your saved key was not replaced."
            }
            return "\(provider) could not verify the key (HTTP \(status)). Try again later; your saved key was not replaced."
        case .unavailable(let provider):
            return "Could not connect to \(provider). Check your internet connection and try again. Your saved key was not replaced."
        case .invalidResponse(let provider):
            return "\(provider) returned an unexpected response. Try the connection check again."
        case .keychainWriteFailed:
            return "macOS Keychain could not save the key. Your existing key was preserved. Please try again."
        case .credentialChanged:
            return "The saved key changed during the connection check. Test the current key again."
        }
    }
}

enum CloudCredentialValidation {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    // https://developers.deepgram.com/guides/fundamentals/authenticating
    // https://docs.speechmatics.com/get-started/authentication
    static func request(target: CloudCredentialTarget, key: String) throws -> URLRequest {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }),
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CloudCredentialValidationError.invalidKey
        }
        let url: URL
        let authorization: String
        switch target {
        case .deepgram:
            url = URL(string: "https://api.deepgram.com/v1/auth/token")!
            authorization = "Token \(key)"
        case .speechmatics(let region):
            guard region.isSupported else { throw CloudCredentialValidationError.unsupportedRegion }
            var components = URLComponents(url: region.endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "1")]
            url = components.url!
            authorization = "Bearer \(key)"
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func validate(target: CloudCredentialTarget, key: String,
                         transport: Transport = send) async throws {
        let request = try request(target: target, key: key)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw CloudCredentialValidationError.unavailable(provider: target.name)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw CloudCredentialValidationError.invalidResponse(provider: target.name)
        }
        guard http.statusCode == 200 else {
            throw CloudCredentialValidationError.rejected(provider: target.name, status: http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !object.isEmpty, object["error"] == nil, object["err_code"] == nil else {
            throw CloudCredentialValidationError.invalidResponse(provider: target.name)
        }
        // Job metadata is used only to authenticate and discarded immediately.
        if case .speechmatics = target, !(object["jobs"] is [Any]) {
            throw CloudCredentialValidationError.invalidResponse(provider: target.name)
        }
    }

    /// Commit a replacement only after authentication, cancellation, and a
    /// concurrent-key-change check. Tests inject storage instead of Keychain.
    @MainActor
    static func checkAndSave(
        target: CloudCredentialTarget,
        replacement: String? = nil,
        defaults: UserDefaults = .standard,
        transport: Transport = send,
        readKey: (String) -> String? = { KeychainStore.get(account: $0) },
        writeKey: (String, String) throws -> Void = { try KeychainStore.set($0, account: $1) }
    ) async throws {
        let previous = readKey(target.account)
        let value = (replacement ?? previous ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if replacement == nil { invalidate(target: target, defaults: defaults) }
        try await validate(target: target, key: value, transport: transport)
        try Task.checkCancellation()
        guard readKey(target.account) == previous else {
            throw CloudCredentialValidationError.credentialChanged
        }
        if replacement != nil {
            do { try writeKey(value, target.account) }
            catch { throw CloudCredentialValidationError.keychainWriteFailed }
        }
        recordSuccess(target: target, key: value, defaults: defaults)
    }

    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: CredentialCheckRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }

    /// Only a digest is persisted, scoped to the selected processing region.
    static func recordSuccess(target: CloudCredentialTarget, key: String, defaults: UserDefaults = .standard) {
        defaults.set(digest(key), forKey: target.receiptKey)
    }

    static func isVerified(target: CloudCredentialTarget, key: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let key, !key.isEmpty else { return false }
        return defaults.string(forKey: target.receiptKey) == digest(key)
    }

    static func savedKeyIsVerified(target: CloudCredentialTarget) -> Bool {
        // Avoid requesting a secret from Keychain until a successful check exists.
        guard UserDefaults.standard.string(forKey: target.receiptKey) != nil else { return false }
        return isVerified(target: target, key: KeychainStore.get(account: target.account))
    }

    static func invalidate(target: CloudCredentialTarget, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: target.receiptKey)
    }

    private static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class CredentialCheckRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
