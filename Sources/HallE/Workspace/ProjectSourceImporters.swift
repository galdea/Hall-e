import Foundation
import CryptoKit

struct NormalizedProjectDocument: Hashable, Sendable {
    var externalId: String
    var title: String
    var author: String?
    var occurredAt: Date?
    var body: String
    var metadata: [String: String]
}

protocol ProjectSourceImporter {
    func load(from location: URL) throws -> [NormalizedProjectDocument]
}

enum ProjectImportError: Error, LocalizedError {
    case unsupportedFile(String)
    case malformedExport(String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let value): "Unsupported import file: \(value)"
        case .malformedExport(let value): "Could not read export: \(value)"
        case .extractionFailed(let value): "Could not extract export: \(value)"
        }
    }
}

struct CodexSessionImporter: ProjectSourceImporter {
    var codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

    func load(from projectRoot: URL) throws -> [NormalizedProjectDocument] {
        let roots = [codexHome.appendingPathComponent("sessions"),
                     codexHome.appendingPathComponent("archived_sessions")]
        let rootPath = projectRoot.standardizedFileURL.path
        var result: [NormalizedProjectDocument] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                guard let document = parse(file: file, projectRootPath: rootPath) else { continue }
                result.append(document)
            }
        }
        return result.sorted { ($0.occurredAt ?? .distantPast) < ($1.occurredAt ?? .distantPast) }
    }

    private func parse(file: URL, projectRootPath: String) -> NormalizedProjectDocument? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var sessionID: String?
        var sessionDate: Date?
        var cwd: String?
        var turns: [(role: String, text: String)] = []

        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { continue }
            if type == "session_meta" {
                sessionID = (payload["id"] ?? payload["session_id"]) as? String
                cwd = payload["cwd"] as? String
                sessionDate = Self.date(payload["timestamp"])
            } else if type == "response_item",
                      let role = payload["role"] as? String,
                      role == "user" || role == "assistant",
                      let visible = Self.visibleText(payload["content"]),
                      let text = Self.redactSecrets(visible),
                      !Self.isInjectedContext(text) {
                turns.append((role, text))
            }
        }

        guard let cwd else { return nil }
        let cwdPath = URL(fileURLWithPath: cwd).standardizedFileURL.path
        guard cwdPath == projectRootPath || cwdPath.hasPrefix(projectRootPath + "/"), !turns.isEmpty else { return nil }
        let body = turns.map { $0.role == "user" ? "**User:** \($0.text)" : "**Codex:** \($0.text)" }
            .joined(separator: "\n\n")
        let firstPrompt = turns.first(where: { $0.role == "user" })?.text
            .replacingOccurrences(of: "\n", with: " ") ?? "Codex session"
        let identity = sessionID ?? Self.digest(file.path)
        return NormalizedProjectDocument(
            externalId: identity,
            title: String(firstPrompt.prefix(100)),
            author: "Codex",
            occurredAt: sessionDate,
            body: String(body.prefix(120_000)),
            metadata: ["cwd": cwdPath, "session_file": file.path]
        )
    }

    private static func visibleText(_ value: Any?) -> String? {
        guard let blocks = value as? [[String: Any]] else { return value as? String }
        let text = blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String,
                  type == "input_text" || type == "output_text" || type == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static func isInjectedContext(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("<environment_context>") || value.hasPrefix("<permissions")
            || value.hasPrefix("# AGENTS.md") || value.hasPrefix("<collaboration_mode>")
    }

    private static func redactSecrets(_ text: String) -> String? {
        var result = text
        let patterns = [
            #"(?i)\b(api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|secret)\b\s*[:=]\s*["']?[^\s,"'}]+"#,
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"\bsk-[A-Za-z0-9_-]{12,}\b"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[redacted credential]",
                                                 options: .regularExpression)
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? TimeInterval { return Date(timeIntervalSince1970: seconds) }
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ChatGPTExportImporter: ProjectSourceImporter {
    func load(from location: URL) throws -> [NormalizedProjectDocument] {
        let file: URL
        var temporaryFolder: URL?
        if location.pathExtension.lowercased() == "zip" {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("halle-chatgpt-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", location.path, folder.path]
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ProjectImportError.extractionFailed(location.lastPathComponent)
            }
            temporaryFolder = folder
            file = folder.appendingPathComponent("conversations.json")
        } else {
            file = location
        }
        defer { if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) } }

        if ["txt", "md"].contains(file.pathExtension.lowercased()) {
            let body = try String(contentsOf: file, encoding: .utf8)
            return [NormalizedProjectDocument(externalId: Self.digest(body),
                                              title: file.deletingPathExtension().lastPathComponent,
                                              author: nil, occurredAt: nil, body: body,
                                              metadata: ["file": location.lastPathComponent])]
        }
        guard file.pathExtension.lowercased() == "json" else {
            throw ProjectImportError.unsupportedFile(location.lastPathComponent)
        }
        let data = try Data(contentsOf: file)
        guard let conversations = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ProjectImportError.malformedExport(file.lastPathComponent)
        }
        return conversations.compactMap(Self.conversation)
    }

    private static func conversation(_ value: [String: Any]) -> NormalizedProjectDocument? {
        guard let mapping = value["mapping"] as? [String: Any] else { return nil }
        let nodes = mapping.values.compactMap { node -> (Double, String, String)? in
            guard let dictionary = node as? [String: Any],
                  let message = dictionary["message"] as? [String: Any],
                  let author = message["author"] as? [String: Any],
                  let role = author["role"] as? String,
                  role == "user" || role == "assistant",
                  let content = message["content"] as? [String: Any],
                  let parts = content["parts"] as? [Any] else { return nil }
            let text = parts.compactMap { $0 as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (message["create_time"] as? Double ?? 0, role, text)
        }.sorted { $0.0 < $1.0 }
        guard !nodes.isEmpty else { return nil }
        let body = nodes.map { $0.1 == "user" ? "**User:** \($0.2)" : "**ChatGPT:** \($0.2)" }
            .joined(separator: "\n\n")
        let title = value["title"] as? String ?? "ChatGPT conversation"
        let id = value["id"] as? String ?? digest(title + body)
        let timestamp = value["create_time"] as? Double ?? nodes.first?.0 ?? 0
        return NormalizedProjectDocument(externalId: id, title: title, author: "ChatGPT",
                                         occurredAt: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil,
                                         body: String(body.prefix(120_000)), metadata: [:])
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct WhatsAppExportImporter: ProjectSourceImporter {
    func load(from location: URL) throws -> [NormalizedProjectDocument] {
        guard location.pathExtension.lowercased() == "txt" else {
            throw ProjectImportError.unsupportedFile(location.lastPathComponent)
        }
        let text = try String(contentsOf: location, encoding: .utf8)
        var messages: [(stamp: String, author: String, body: String)] = []
        let expressions = [
            try NSRegularExpression(pattern: #"^\[([^\]]+)\]\s*([^:]+):\s?(.*)$"#),
            try NSRegularExpression(pattern: #"^(.+?)\s+-\s+([^:]+):\s?(.*)$"#),
        ]
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            var match: (String, String, String)?
            for expression in expressions {
                guard let found = expression.firstMatch(in: line, range: range), found.numberOfRanges == 4,
                      let stampRange = Range(found.range(at: 1), in: line),
                      let authorRange = Range(found.range(at: 2), in: line),
                      let bodyRange = Range(found.range(at: 3), in: line) else { continue }
                match = (String(line[stampRange]), String(line[authorRange]), String(line[bodyRange]))
                break
            }
            if let match {
                messages.append((match.0, match.1, match.2))
            } else if !line.isEmpty, !messages.isEmpty {
                messages[messages.count - 1].body += "\n" + line
            }
        }
        return messages.compactMap { message in
            let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, !body.contains("Messages and calls are end-to-end encrypted") else { return nil }
            let identity = Self.digest("\(message.stamp)|\(message.author)|\(body)")
            return NormalizedProjectDocument(externalId: identity,
                                             title: String(body.replacingOccurrences(of: "\n", with: " ").prefix(90)),
                                             author: message.author.trimmingCharacters(in: .whitespaces),
                                             occurredAt: Self.parseDate(message.stamp), body: body,
                                             metadata: ["chat_file": location.lastPathComponent])
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formats = [
            "dd/MM/yyyy, HH:mm:ss", "dd/MM/yyyy, HH:mm", "dd/MM/yy, HH:mm",
            "MM/dd/yyyy, h:mm:ss a", "MM/dd/yyyy, h:mm a", "MM/dd/yy, h:mm a",
            "yyyy-MM-dd, HH:mm:ss", "yyyy-MM-dd, HH:mm",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
