import Foundation
import CryptoKit

/// PKCE (RFC 7636) code verifier/challenge pair + random state, base64url-encoded.
struct PKCE {
    let verifier: String
    let challenge: String
    let state: String

    init() {
        verifier = Self.randomURLSafe(bytes: 64)
        state = Self.randomURLSafe(bytes: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(digest).base64URLEncodedString()
    }

    /// Random unreserved string via base64url of `bytes` random bytes.
    static func randomURLSafe(bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return Data(buf).base64URLEncodedString()
    }
}

extension Data {
    /// base64url without padding (RFC 4648 §5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
