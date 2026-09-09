import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section("Hall-e") {
                Text(PublicUICopy.text("Record, transcribe, and organize your meetings. Calendar, notes, and AI integrations are optional.", "Graba, transcribe y organiza tus reuniones. Las integraciones de calendario, notas e IA son opcionales."))
                LabeledContent(PublicUICopy.text("Version", "Versión")) {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                }
                LabeledContent("Build") { Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—") }
                Link(destination: CommunityLinks.latestRelease) {
                    Label(PublicUICopy.text("Check for updates / share Hall-e", "Buscar actualizaciones / compartir Hall-e"), systemImage: "arrow.down.circle")
                }
                Text(PublicUICopy.text("Opens the latest download. Quit Hall-e before replacing it in Applications; your recordings and notes stay on this Mac.", "Abre la descarga más reciente. Cierra Hall-e antes de reemplazarlo en Aplicaciones; tus grabaciones y notas permanecen en este Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(PublicUICopy.text("Open source & support", "Código abierto y apoyo")) {
                Link(destination: CommunityLinks.github) {
                    Label(PublicUICopy.text("Star Hall-e on GitHub", "Dale una estrella a Hall-e en GitHub"), systemImage: "star")
                }
                Link(destination: CommunityLinks.support) {
                    Label(PublicUICopy.text("Support Hall-e · buy me a coffee", "Apoya Hall-e · invítame un café"), systemImage: "cup.and.saucer")
                }
                Text(PublicUICopy.text("Support information opens in the GitHub README. A direct donation link is not available yet.", "La información de apoyo se abre en el README de GitHub. Aún no hay un enlace directo para donaciones."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(PublicUICopy.text("About & support", "Acerca de y apoyo"))
    }
}
