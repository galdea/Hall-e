import Foundation
import Security

/// Thin wrapper over the login keychain (kSecClassGenericPassword).
/// Used for Google refresh tokens and LLM API keys. Never logs values.
///
/// Deliberately uses the file-based login keychain (no kSecUseDataProtectionKeychain)
/// so a self-signed app without Apple-issued entitlements can store items whose
/// ACL is keyed on our stable designated requirement.
enum KeychainStore {
    static let service = "cl.gabriel.hall-e"

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case invalidUTF8

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
                return "Keychain error: \(msg)"
            case .invalidUTF8: return "The saved Keychain item is not valid UTF-8."
            }
        }
    }

    /// Store (or replace) a secret for `account`.
    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Retrieve a secret, or nil if absent.
    static func get(account: String) -> String? {
        try? getThrowing(account: account)
    }

    /// Retrieve a secret, distinguishing an absent item from a denied or failed read.
    static func getThrowing(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidUTF8
        }
        return value
    }

    /// Keychain operations can wait for user authorization. Keep them off the UI actor.
    static func getAsync(account: String) async throws -> String? {
        try await Task.detached(priority: .userInitiated) {
            try getThrowing(account: account)
        }.value
    }

    static func setAsync(_ value: String, account: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try set(value, account: account)
        }.value
    }

    @discardableResult
    static func deleteAsync(account: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            delete(account: account)
        }.value
    }

    static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Account key conventions

    static func googleRefreshAccount(email: String) -> String { "google-refresh:\(email)" }
    static func llmKeyAccount(providerKind: String, host: String) -> String { "\(providerKind)#\(host)" }
    static let deepgramTranscriptionAccount = "deepgram#prerecorded-transcription"
    /// A second Deepgram account, used only after the primary reports no credit.
    /// It is a different account with independent credit, not a second key on the
    /// same one, so it survives the primary's free grant being used up.
    static let deepgramFallbackTranscriptionAccount = "deepgram#prerecorded-transcription-fallback"
    static let speechmaticsTranscriptionAccount = "speechmatics#batch-transcription"
}
