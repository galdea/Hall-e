import Testing
import Foundation
@testable import HallE

@Suite("LoopbackServer")
struct LoopbackServerTests {
    @Test func bindsToARealNonZeroPort() async throws {
        let server = LoopbackServer()
        defer { server.stop() }
        let port = try await server.start()
        // The bug was returning 0 (NWListener.port is .any until .ready).
        #expect(port != 0)
        #expect(port >= 1024)  // ephemeral range, never a privileged/unsafe low port
        // Redirect URI must carry the real port.
        #expect(LoopbackServer.redirectURI(port: port) == "http://127.0.0.1:\(port)")
    }

    @Test func twoServersGetDistinctPorts() async throws {
        let a = LoopbackServer(); let b = LoopbackServer()
        defer { a.stop(); b.stop() }
        let pa = try await a.start()
        let pb = try await b.start()
        #expect(pa != 0 && pb != 0)
        #expect(pa != pb)
    }
}
