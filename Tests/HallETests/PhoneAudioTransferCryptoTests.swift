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
