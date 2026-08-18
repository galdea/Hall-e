import Foundation

struct BriefingDesignProfile: Codable, Equatable {
    static let schema = "halle.briefing-design.v1"
    var schemaVersion: String
    var profileVersion: Int
    var accentColor: String
    var backgroundColor: String
    var textColor: String
    var logoFileName: String?
    var fontFamily: String
    var fontFallbacks: [String]
    var density: String
    var marginMM: Double
    var sectionOrder: [String]
    var language: String
    var tone: String

    static let corporateCloseKnit = BriefingDesignProfile(
        schemaVersion: schema, profileVersion: 1, accentColor: "#183B56",
        backgroundColor: "#F7F5F0", textColor: "#17212B", logoFileName: nil,
        fontFamily: "Avenir Next", fontFallbacks: ["Helvetica Neue", "sans-serif"],
        density: "compact", marginMM: 12,
        sectionOrder: ["objectives", "tasks", "decisions", "risks", "milestones", "openQuestions"],
        language: "es", tone: "corporate-close-knit")

    func validated(designDirectory: URL?) -> Self {
        var value = self
        if schemaVersion != Self.schema { value.schemaVersion = Self.schema }
        if !Self.validHex(accentColor) { value.accentColor = Self.corporateCloseKnit.accentColor }
        if !Self.validHex(backgroundColor) { value.backgroundColor = Self.corporateCloseKnit.backgroundColor }
        if !Self.validHex(textColor) { value.textColor = Self.corporateCloseKnit.textColor }
        value.marginMM = min(20, max(8, marginMM))
        value.density = ["compact", "comfortable"].contains(density) ? density : "compact"
        value.sectionOrder = Self.requiredSections + sectionOrder.filter { !Self.requiredSections.contains($0) }
        value.sectionOrder = Array(NSOrderedSet(array: value.sectionOrder)) as? [String] ?? Self.corporateCloseKnit.sectionOrder
        if let name = logoFileName {
            let allowed = ["png", "jpg", "jpeg"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
            let simple = URL(fileURLWithPath: name).lastPathComponent == name
            let exists = designDirectory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) } ?? false
            if !allowed || !simple || !exists { value.logoFileName = nil }
        }
        return value
    }

    private static let requiredSections = ["objectives", "tasks", "decisions"]
    private static func validHex(_ value: String) -> Bool {
        value.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil
    }
}

enum BriefingDesignProfileStore {
    static let fileName = "briefing-design.json"

    static func load(projectName: String?, service: MeetingNoteService?) -> (BriefingDesignProfile, URL?) {
        guard let projectName, let service else { return (.corporateCloseKnit, nil) }
        let builder = VaultPathBuilder(config: service.config)
        let relative = "\(builder.projectFolder(projectName))/Design"
        let directory = builder.absoluteURL(relative, vaultURL: service.vaultURL)
        let file = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: file),
              let profile = try? JSONDecoder().decode(BriefingDesignProfile.self, from: data) else {
            return (.corporateCloseKnit, directory)
        }
        return (profile.validated(designDirectory: directory), directory)
    }

    /// Imports only a validated JSON profile and one local raster logo. The
    /// repository is never consulted again at render time.
    static func importFromRepository(_ repository: URL, projectName: String,
                                     service: MeetingNoteService) throws -> URL {
        let sourceDirectory = repository.appendingPathComponent(".halle", isDirectory: true)
        let source = sourceDirectory.appendingPathComponent(fileName)
        let data = try Data(contentsOf: source)
        let decoded = try JSONDecoder().decode(BriefingDesignProfile.self, from: data)
        let builder = VaultPathBuilder(config: service.config)
        let destination = builder.absoluteURL("\(builder.projectFolder(projectName))/Design", vaultURL: service.vaultURL)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var profile = decoded
        if let logo = decoded.logoFileName {
            let sourceLogo = sourceDirectory.appendingPathComponent(logo).standardizedFileURL
            guard sourceLogo.deletingLastPathComponent() == sourceDirectory.standardizedFileURL,
                  ["png", "jpg", "jpeg"].contains(sourceLogo.pathExtension.lowercased()) else {
                profile.logoFileName = nil
                return try write(profile.validated(designDirectory: destination), to: destination)
            }
            let destinationLogo = destination.appendingPathComponent(sourceLogo.lastPathComponent)
            if FileManager.default.fileExists(atPath: destinationLogo.path) { try FileManager.default.removeItem(at: destinationLogo) }
            try FileManager.default.copyItem(at: sourceLogo, to: destinationLogo)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationLogo.path)
        }
        return try write(profile.validated(designDirectory: destination), to: destination)
    }

    @discardableResult private static func write(_ profile: BriefingDesignProfile, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
