import Foundation
import Network

/// One-shot loopback HTTP listener for the OAuth redirect on 127.0.0.1:<random>.
/// Google's native-app flow: start a listener on an ephemeral port, receive the
/// GET /?code=…&state=… redirect, reply with a small page, then stop.
final class LoopbackServer {
    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "cl.gabriel.hall-e.loopback")

    /// Set before opening the browser; invoked once with the redirect result.
    var onCallback: ((CallbackResult) -> Void)?

    struct CallbackResult {
        let code: String?
        let state: String?
        let error: String?
    }

    /// Binds a loopback listener on an ephemeral port and returns it once the
    /// listener is actually `.ready`. Before `.ready`, `listener.port` reports
    /// `.any` (raw value 0), which must NOT be used as the redirect port.
    /// Set `onCallback` before triggering the redirect.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.connection = conn
            conn.start(queue: self.queue)
            self.receive(on: conn)
        }

        return try await withCheckedThrowingContinuation { cont in
            let guardOnce = ResumeGuard()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue, port != 0 {
                        if guardOnce.tryResume() { cont.resume(returning: port) }
                    }
                case .failed(let error):
                    if guardOnce.tryResume() { cont.resume(throwing: error) }
                case .cancelled:
                    if guardOnce.tryResume() {
                        cont.resume(throwing: NSError(domain: "LoopbackServer", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Loopback listener cancelled before ready."]))
                    }
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }
    }

    static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)" }

    func stop() {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let request = String(data: data, encoding: .utf8) {
                let result = Self.parseRequestLine(request)
                self.reply(on: conn, success: result.error == nil && result.code != nil)
                self.onCallback?(result)
            } else if error != nil {
                self.onCallback?(CallbackResult(code: nil, state: nil, error: error?.localizedDescription))
            }
        }
    }

    /// Parse "GET /?code=...&state=... HTTP/1.1" into components.
    static func parseRequestLine(_ request: String) -> CallbackResult {
        guard let firstLine = request.split(separator: "\r\n").first,
              let pathPart = firstLine.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://127.0.0.1\(pathPart)")
        else {
            return CallbackResult(code: nil, state: nil, error: "Malformed redirect request")
        }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return CallbackResult(code: value("code"), state: value("state"), error: value("error"))
    }

    private func reply(on conn: NWConnection, success: Bool) {
        let title = success ? "Hall-e is connected" : "Authorization failed"
        let body = success
            ? "You can close this window and return to Hall-e."
            : "Something went wrong. Return to Hall-e and try again."
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>body{font:16px -apple-system,system-ui;margin:15% auto;max-width:28rem;text-align:center;color:#111}
        @media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#eee}}
        h1{font-size:1.3rem}</style></head>
        <body><h1>\(title)</h1><p>\(body)</p></body></html>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
