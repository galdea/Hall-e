import Testing
import Foundation
import CryptoKit
@testable import HallE

@Suite("PKCE + OAuth")
struct OAuthPKCETests {
    @Test func challengeIsBase64URLSha256OfVerifier() {
        let pkce = PKCE()
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8))).base64URLEncodedString()
        #expect(pkce.challenge == expected)
        // base64url: no +, /, or = padding
        #expect(!pkce.challenge.contains("+"))
        #expect(!pkce.challenge.contains("/"))
        #expect(!pkce.challenge.contains("="))
    }

    @Test func verifierAndStateAreUniqueAndSufficientlyLong() {
        let a = PKCE(); let b = PKCE()
        #expect(a.verifier != b.verifier)
        #expect(a.state != b.state)
        #expect(a.verifier.count >= 43)  // RFC 7636 minimum
    }

    @Test func base64URLKnownVector() {
        // "foobar" → base64 "Zm9vYmFy" (no url-unsafe chars here, but verifies mapping)
        #expect(Data("foobar".utf8).base64URLEncodedString() == "Zm9vYmFy")
        // bytes that produce + and / in std base64 → must map to - and _
        let bytes = Data([0xFB, 0xEF, 0xBE])  // std base64 "++++"→ "-" "_" territory
        let std = bytes.base64EncodedString()
        let url = bytes.base64URLEncodedString()
        #expect(!url.contains("+") && !url.contains("/"))
        #expect(url == std.replacingOccurrences(of: "+", with: "-")
                          .replacingOccurrences(of: "/", with: "_")
                          .replacingOccurrences(of: "=", with: ""))
    }

    @Test func authURLContainsRequiredParams() {
        let config = GoogleClientConfig(clientId: "cid.apps.googleusercontent.com",
                                        clientSecret: "secret",
                                        authURI: "https://accounts.google.com/o/oauth2/v2/auth",
                                        tokenURI: "https://oauth2.googleapis.com/token")
        let client = GoogleOAuthClient(config: config)
        let pkce = PKCE()
        let url = client.buildAuthURL(pkce: pkce, redirectURI: "http://127.0.0.1:49200")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == "cid.apps.googleusercontent.com")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["scope"] == "https://www.googleapis.com/auth/calendar.readonly")
        #expect(items["access_type"] == "offline")
        #expect(items["redirect_uri"] == "http://127.0.0.1:49200")
    }

    @Test func parseClientJSONHandlesInstalledWrapper() throws {
        let json = """
        {"installed":{"client_id":"abc","client_secret":"xyz",
        "auth_uri":"https://accounts.google.com/o/oauth2/auth",
        "token_uri":"https://oauth2.googleapis.com/token","redirect_uris":["http://localhost"]}}
        """
        let cfg = try GoogleClientConfig.parse(Data(json.utf8))
        #expect(cfg.clientId == "abc")
        #expect(cfg.clientSecret == "xyz")
        #expect(cfg.tokenURI == "https://oauth2.googleapis.com/token")
    }

    @Test func parseRedirectRequestLineExtractsCodeAndState() {
        let req = "GET /?code=4/abc123&state=xyzstate&scope=cal HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let result = LoopbackServer.parseRequestLine(req)
        #expect(result.code == "4/abc123")
        #expect(result.state == "xyzstate")
        #expect(result.error == nil)
    }
}
