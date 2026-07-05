import Foundation

/// Persisted, user-editable project definitions + aliases. Seeded on first run
/// with Gabriel's known projects.
final class AliasStore: @unchecked Sendable {
    static let shared = AliasStore()

    private(set) var projects: [Project]
    private let lock = NSLock()

    private init() {
        if let data = try? Data(contentsOf: AppPaths.aliasesFile),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        } else {
            projects = AliasStore.seed
            save()
        }
    }

    func reload() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: AppPaths.aliasesFile),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        }
    }

    func save() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: AppPaths.aliasesFile, options: [.atomic])
        }
    }

    func update(_ project: Project) {
        lock.lock()
        if let i = projects.firstIndex(where: { $0.id == project.id }) { projects[i] = project }
        else { projects.append(project) }
        lock.unlock()
        save()
    }

    /// Projects with people-derived aliases folded in, for classification only
    /// (the editor still reads raw `projects`). Each tagged person contributes
    /// their emails as strong `.email` aliases and their full name as a weak
    /// `.personName` alias to every project they're assigned to.
    func classificationProjects(people: [Person] = PeopleStore.shared.people) -> [Project] {
        var byId = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        for person in people where !person.isArchived {
            for pid in person.projectIds {
                guard byId[pid] != nil else { continue }
                for email in person.emails where !email.isEmpty {
                    byId[pid]!.aliases.append(ProjectAlias(email, .email, .strong))
                }
                let name = person.name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    byId[pid]!.aliases.append(ProjectAlias(name, .personName, .weak))
                }
            }
        }
        return projects.map { p in
            var merged = byId[p.id]!
            merged.aliases = Array(Set(merged.aliases))
            return merged
        }
    }

    func project(named name: String) -> Project? {
        projects.first { $0.name == name }
    }

    // MARK: - Seed

    static let seed: [Project] = [
        Project(id: "accurate", name: "Accurate", aliases:
            [ProjectAlias("Accurate", .projectName, .strong),
             ProjectAlias("getaccurate.cl", .domain, .strong),
             ProjectAlias("sociograma", .keyword, .strong),
             ProjectAlias("director dashboard", .keyword, .strong),
             ProjectAlias("dashboard director", .keyword, .strong),
             ProjectAlias("panel director", .keyword, .strong),
             ProjectAlias("clima escolar", .keyword, .strong),
             ProjectAlias("red de colegios", .keyword, .strong),
             ProjectAlias("cuestionario", .keyword, .normal),
             ProjectAlias("funcionarios", .keyword, .normal),
             ProjectAlias("colegio", .keyword, .normal),
             ProjectAlias("colegios", .keyword, .normal),
             ProjectAlias("instrumento", .keyword, .weak),
             ProjectAlias("evaluación", .keyword, .weak),
             ProjectAlias("Accenture", .keyword, .normal)]),
        Project(id: "cazadescuentos", name: "Cazadescuentos", aliases:
            [ProjectAlias("Cazadescuentos", .projectName, .strong),
             ProjectAlias("AdSense", .keyword, .strong),
             ProjectAlias("AdMob", .keyword, .strong),
             ProjectAlias("Cloudflare Workers", .keyword, .strong),
             ProjectAlias("descuentos", .keyword, .normal),
             ProjectAlias("beneficios", .keyword, .normal),
             ProjectAlias("tarjetas", .keyword, .normal),
             ProjectAlias("ingesta", .keyword, .normal),
             ProjectAlias("bancos", .keyword, .weak),
             ProjectAlias("restaurantes", .keyword, .weak),
             ProjectAlias("bares", .keyword, .weak),
             ProjectAlias("cafés", .keyword, .weak),
             ProjectAlias("Google Maps", .keyword, .weak),
             ProjectAlias("mapa", .keyword, .weak)]),
        Project(id: "vina-cousino-macul", name: "Viña Cousiño Macul", aliases:
            [ProjectAlias("Cousiño Macul", .projectName, .strong),
             ProjectAlias("Cousiño", .projectName, .strong),
             ProjectAlias("Tourpay", .keyword, .strong),
             ProjectAlias("manual de marca", .keyword, .strong),
             ProjectAlias("ficha técnica", .keyword, .normal),
             ProjectAlias("viña", .keyword, .normal),
             ProjectAlias("vinos", .keyword, .normal),
             ProjectAlias("wine", .keyword, .normal),
             ProjectAlias("tour", .keyword, .weak),
             ProjectAlias("booking", .keyword, .weak),
             ProjectAlias("reservas", .keyword, .weak),
             ProjectAlias("landing", .keyword, .weak)]),
        Project(id: "matriztica", name: "Matríztica", aliases:
            [ProjectAlias("Matríztica", .projectName, .strong),
             ProjectAlias("biología-cultural", .keyword, .strong),
             ProjectAlias("mentor virtual", .keyword, .strong),
             ProjectAlias("Delphi", .keyword, .normal),
             ProjectAlias("corpus", .keyword, .normal),
             ProjectAlias("chatbot", .keyword, .weak),
             ProjectAlias("reportajes", .keyword, .weak),
             ProjectAlias("entrevistas", .keyword, .weak),
             ProjectAlias("Sebastián", .personName, .weak)]),
        Project(id: "rumbo", name: "Rumbo", aliases:
            [ProjectAlias("Rumbo", .projectName, .strong),
             ProjectAlias("Vambe", .keyword, .strong),
             ProjectAlias("organigrama", .keyword, .normal),
             ProjectAlias("flujo", .keyword, .weak),
             ProjectAlias("asistente", .keyword, .weak),
             ProjectAlias("agente", .keyword, .weak),
             ProjectAlias("WhatsApp", .keyword, .weak),
             ProjectAlias("assistant", .keyword, .weak)]),
        Project(id: "el-mundialero", name: "El Mundialero", aliases:
            [ProjectAlias("Mundialero", .projectName, .strong),
             ProjectAlias("calendario partidos", .keyword, .strong),
             ProjectAlias("notificaciones partidos", .keyword, .strong),
             ProjectAlias("fixture", .keyword, .normal),
             ProjectAlias("selecciones", .keyword, .normal),
             ProjectAlias("mundial", .keyword, .normal),
             ProjectAlias("fútbol", .keyword, .weak),
             ProjectAlias("grupos", .keyword, .weak)]),
        Project(id: "oasis", name: "Oasis", aliases:
            [ProjectAlias("Oasis", .projectName, .strong),
             ProjectAlias("OpenPath", .keyword, .strong),
             ProjectAlias("Nimbio", .keyword, .strong),
             ProjectAlias("lockbox", .keyword, .strong),
             ProjectAlias("guest experience", .keyword, .strong),
             ProjectAlias("check-in", .keyword, .normal),
             ProjectAlias("checkout", .keyword, .normal),
             ProjectAlias("arrivals", .keyword, .normal),
             ProjectAlias("maintenance", .keyword, .weak),
             ProjectAlias("guest", .keyword, .weak),
             ProjectAlias("August", .keyword, .weak)]),
    ]
}
