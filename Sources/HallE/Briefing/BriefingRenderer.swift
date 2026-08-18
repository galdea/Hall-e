import Foundation
import WebKit

enum BriefingRenderer {
    static func markdown(_ briefing: MeetingBriefing) -> String {
        var lines = ["# \(briefing.headline)", ""]
        append("Objetivos", briefing.objectives, to: &lines)
        append("Tareas individuales", briefing.tasks, to: &lines, tasks: true)
        append("Decisiones", briefing.decisions, to: &lines)
        append("Riesgos y bloqueos", briefing.risks, to: &lines)
        append("Próximos hitos", briefing.milestones, to: &lines)
        append("Preguntas abiertas", briefing.openQuestions, to: &lines)
        lines += ["", "---", "_Reporte Hall-E · \(briefing.model) · evidencia: \(briefing.transcriptHash.prefix(12))_", ""]
        return lines.joined(separator: "\n")
    }

    static func html(_ briefing: MeetingBriefing, profile: BriefingDesignProfile,
                     designDirectory: URL?, compact: Bool = false) -> String {
        let safe = profile.validated(designDirectory: designDirectory)
        let core = sectionHTML("Objetivos", briefing.objectives) + sectionHTML("Tareas", briefing.tasks, tasks: true) + sectionHTML("Decisiones", briefing.decisions)
        let optionalItems = briefing.risks + briefing.milestones + briefing.openQuestions
        let optional = compact
            ? "<section><h2>Seguimiento</h2><p>\(escape(optionalItems.prefix(5).map(\.title).joined(separator: " · ")))</p><p class='overflow'>Detalle completo en la nota Markdown.</p></section>"
            : sectionHTML("Riesgos", briefing.risks) + sectionHTML("Hitos", briefing.milestones) + sectionHTML("Preguntas", briefing.openQuestions)
        let logo = safe.logoFileName.map { "<img class='logo' src='\(escape($0))' alt='Project logo'>" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        @page { size: A4; margin: 0; } * { box-sizing:border-box; } html,body { margin:0; padding:0; }
        body { color:\(safe.textColor); background:white; font-family:'\(escape(safe.fontFamily))',\(safe.fontFallbacks.map { "'\(escape($0))'" }.joined(separator: ",")); }
        .report { max-height:594mm; overflow:hidden; padding:\(safe.marginMM)mm; column-count:1; }
        header { display:flex; align-items:flex-start; gap:8mm; border-bottom:2px solid \(safe.accentColor); padding-bottom:5mm; margin-bottom:5mm; }
        .logo { width:24mm; max-height:16mm; object-fit:contain; } h1 { font-size:23pt; line-height:1.08; margin:0; color:\(safe.accentColor); }
        h2 { font-size:11pt; text-transform:uppercase; letter-spacing:.07em; color:\(safe.accentColor); margin:5mm 0 2mm; }
        ul { margin:0; padding-left:5mm; } li,p { font-size:\(compact ? "8.4" : "9.2")pt; line-height:1.28; margin:0 0 1.6mm; }
        .meta,.evidence,.overflow { color:#66717c; font-size:7.5pt; } section { break-inside:avoid; }
        </style></head><body><main class="report"><header>\(logo)<div><h1>\(escape(briefing.headline))</h1><div class="meta">Hall-E · \(escape(briefing.model)) · \(escape(briefing.generatedAt))</div></div></header>\(core)\(optional)</main></body></html>
        """
    }

    @MainActor static func renderPDF(_ briefing: MeetingBriefing, profile: BriefingDesignProfile,
                                     designDirectory: URL?, destination: URL) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 595, height: 1684), configuration: configuration)
        let waiter = BriefingNavigationWaiter(); webView.navigationDelegate = waiter
        webView.loadHTMLString(html(briefing, profile: profile, designDirectory: designDirectory), baseURL: designDirectory)
        try await waiter.wait()
        let pdf = try await webView.pdf(configuration: WKPDFConfiguration())
        try pdf.write(to: destination, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func append(_ title: String, _ items: [BriefingItem], to lines: inout [String], tasks: Bool = false) {
        lines += ["## \(title)"]
        if items.isEmpty { lines += ["_(Sin elementos con evidencia.)_", ""]; return }
        for item in items.sorted(by: { $0.priority < $1.priority }) {
            var line = tasks ? "- [ ] \(item.title)" : "- \(item.title)"
            if tasks { line += " — \(item.ownerKind == .unassigned ? "Unassigned" : item.ownerName ?? "Unassigned")" }
            if let date = item.explicitDate { line += " · \(date)" }
            lines.append(line)
            if let detail = item.detail, !detail.isEmpty { lines.append("  \(detail)") }
            lines.append("  _Evidence: \(item.evidence.map { "u\($0.utteranceIndex) @ \(Int($0.start))s" }.joined(separator: ", "))_")
        }
        lines.append("")
    }

    private static func sectionHTML(_ title: String, _ items: [BriefingItem], tasks: Bool = false) -> String {
        guard !items.isEmpty else { return "" }
        let rows = items.sorted(by: { $0.priority < $1.priority }).map { item -> String in
            let owner = tasks ? " <span class='meta'>— \(escape(item.ownerKind == .unassigned ? "Unassigned" : item.ownerName ?? "Unassigned"))\(item.explicitDate.map { " · \(escape($0))" } ?? "")</span>" : ""
            return "<li><strong>\(escape(item.title))</strong>\(owner)\(item.detail.map { "<br>\(escape($0))" } ?? "")</li>"
        }.joined()
        return "<section><h2>\(escape(title))</h2><ul>\(rows)</ul></section>"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

@MainActor private final class BriefingNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resolve(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resolve(.failure(error)) }
    private func resolve(_ value: Result<Void, Error>) {
        if let continuation { self.continuation = nil; continuation.resume(with: value) } else { result = value }
    }
}

private extension WKWebView {
    @MainActor func pdf(configuration: WKPDFConfiguration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            createPDF(configuration: configuration) { continuation.resume(with: $0) }
        }
    }
}
