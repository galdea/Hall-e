import Foundation
import AppKit

/// Chrome Native Messaging helper. It receives the extension's framed JSON on
/// stdin, writes one private file per message, and replies with a tiny success
/// object. It has no network code and never receives or handles audio.
private let queueDirectory: URL = {
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Hall-e/CallCapture/Incoming", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    return root
}()

private struct Envelope: Decodable {
    let version: Int
    let type: String
    let tabId: Int?
    let url: String
    let title: String?
    let detectedAt: Double

    var isSane: Bool {
        version == 1 && ["opened", "ended", "tab-closed"].contains(type)
            && (tabId ?? 0) >= 0 && URL(string: url)?.scheme?.lowercased() == "https"
            && detectedAt > 0
    }
}

private func readExactly(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        let next = FileHandle.standardInput.readData(ofLength: count - data.count)
        guard !next.isEmpty else { return nil }
        data.append(next)
    }
    return data
}

private func reply(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    var length = UInt32(data.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
    FileHandle.standardOutput.write(data)
}

while let header = readExactly(4) {
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    guard length > 0, length <= 64 * 1024 else {
        reply(["ok": false, "error": "invalid message framing"])
        break
    }
    guard let data = readExactly(Int(length)) else {
        reply(["ok": false, "error": "incomplete message"])
        break
    }
    guard let message = try? JSONDecoder().decode(Envelope.self, from: data), message.isSane else {
        reply(["ok": false, "error": "invalid message"])
        continue
    }
    do {
        let destination = queueDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try data.write(to: destination, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        // Native hosts may be launched while Hall-e is closed. Ask Launch
        // Services to bring the local app up so it can drain the private queue;
        // failure is harmless because the message remains durable for next run.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "cl.gabriel.hall-e").isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "cl.gabriel.hall-e") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
        }
        reply(["ok": true])
    } catch {
        reply(["ok": false, "error": "queue unavailable"])
    }
}
