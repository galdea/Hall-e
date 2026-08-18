import Foundation

/// Strict parser for the tiny payload produced by Hall-e's Chrome extension.
/// The extension is not a recording authority: malformed or unsupported
/// messages are discarded before the UI ever sees them.
struct ChromeNativeMessage: Codable, Equatable {
    var version: Int
    var type: CallLaunchType
    var tabID: Int?
    var url: String
    var title: String?
    var detectedAt: Date

    enum CodingKeys: String, CodingKey { case version, type, tabID = "tabId", url, title, detectedAt }

    init(version: Int, type: CallLaunchType, tabID: Int?, url: String, title: String?, detectedAt: Date) {
        self.version = version; self.type = type; self.tabID = tabID
        self.url = url; self.title = title; self.detectedAt = detectedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        type = try values.decode(CallLaunchType.self, forKey: .type)
        tabID = try values.decodeIfPresent(Int.self, forKey: .tabID)
        url = try values.decode(String.self, forKey: .url)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        if let milliseconds = try? values.decode(Double.self, forKey: .detectedAt) {
            detectedAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        } else if let value = try? values.decode(String.self, forKey: .detectedAt),
                  let date = ISO8601DateFormatter().date(from: value) {
            detectedAt = date
        } else {
            throw DecodingError.dataCorruptedError(forKey: .detectedAt, in: values,
                                                   debugDescription: "detectedAt must be epoch milliseconds or ISO-8601")
        }
    }

    func launch() -> CallLaunch {
        CallLaunch(version: version, type: type, tabID: tabID, url: url, title: title, detectedAt: detectedAt)
    }
}

enum ChromeNativeMessageValidator {
    static func validate(_ message: ChromeNativeMessage,
                         customDomains: [String] = AppPreferences.customCallDomains) -> CallLaunch? {
        guard message.version == 1,
              message.tabID.map({ $0 >= 0 }) ?? true,
              let url = URL(string: message.url),
              url.scheme?.lowercased() == "https",
              CallIdentity.make(url: url, customDomains: customDomains) != nil else { return nil }
        // A future clock or stale re-delivery should never surface a surprise
        // prompt after a long period offline.
        guard abs(message.detectedAt.timeIntervalSinceNow) < 24 * 60 * 60 else { return nil }
        return message.launch()
    }
}

enum BrowserCallMessageQueue {
    @discardableResult
    static func enqueue(rawPayload: Data, directory: URL = AppPaths.callMessageQueueDirectory,
                        customDomains: [String] = AppPreferences.customCallDomains) -> Bool {
        guard let message = try? JSONDecoder().decode(ChromeNativeMessage.self, from: rawPayload),
              ChromeNativeMessageValidator.validate(message, customDomains: customDomains) != nil else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(UUID().uuidString).json")
            try rawPayload.write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            Log.rec.error("could not queue browser call message: \(error, privacy: .public)")
            return false
        }
    }

    static func drain(directory: URL = AppPaths.callMessageQueueDirectory,
                      customDomains: [String] = AppPreferences.customCallDomains) -> [CallLaunch] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                         includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let message = try? JSONDecoder().decode(ChromeNativeMessage.self, from: data) else { return nil }
            return ChromeNativeMessageValidator.validate(message, customDomains: customDomains)
        }
    }
}

enum ChromeNativeHostInstaller {
    static let hostName = "cl.gabriel.halle.callcapture"

    static var chromeManifestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(hostName).json")
    }

    static var extensionDirectory: URL? {
        let directory = AppPaths.browserExtensionDirectory
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) {
            return directory
        }
        return try? prepareExtension()
    }

    /// Copies the versioned resource out of the app bundle once so Chrome can
    /// load a stable unpacked directory. The copy is local, private to Hall-e,
    /// and contains no user data.
    @discardableResult
    static func prepareExtension(destination: URL = AppPaths.browserExtensionDirectory) throws -> URL {
        guard let bundled = Bundle.module.url(forResource: "CallCaptureExtension", withExtension: nil) else {
            throw InstallError.extensionNotBundled
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        // Replace only files that belong to the extension; do not remove an
        // unknown user file from the Application Support directory.
        for source in try fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
        }
        return destination
    }

    static func install(extensionID: String) throws {
        let id = extensionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil else {
            throw InstallError.invalidExtensionID
        }
        guard let host = nativeHostExecutableURL() else {
            throw InstallError.hostNotBundled
        }
        try FileManager.default.createDirectory(at: chromeManifestURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "name": hostName,
            "description": "Hall-e local browser call capture",
            "path": host.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(id)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: chromeManifestURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: chromeManifestURL.path)
        AppPreferences.chromeExtensionID = id
    }

    private static func nativeHostExecutableURL() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            // Packaged app: Contents/MacOS/Hall-e and the helper are siblings.
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("CallCaptureNativeHost"),
            // `swift run`: both executable products live in .build/<config>/.
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("CallCaptureNativeHost"),
        ].compactMap { $0 }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    enum InstallError: LocalizedError {
        case invalidExtensionID, hostNotBundled, extensionNotBundled
        var errorDescription: String? {
            switch self {
            case .invalidExtensionID: "Enter the 32-character ID Chrome shows for the Hall-e extension."
            case .hostNotBundled: "The native helper is not present in this Hall-e build."
            case .extensionNotBundled: "The Chrome extension is not present in this Hall-e build."
            }
        }
    }
}
