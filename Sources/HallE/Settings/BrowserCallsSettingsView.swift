import SwiftUI
import AppKit
import AVFoundation

struct BrowserCallsSettingsView: View {
    @State private var enabledSources = AppPreferences.enabledCallSources
    @State private var customDomains = AppPreferences.customCallDomains
    @State private var newDomain = ""
    @State private var extensionID = AppPreferences.chromeExtensionID ?? ""
    @State private var extensionFolder: URL?
    @State private var statusMessage: String?

    var body: some View {
        Form {
            detectionSection
            extensionSection
            customDomainsSection
            permissionSection
            statusSection
        }
        .formStyle(.grouped)
        .navigationTitle("Browser & Calls")
        .onAppear { prepareExtension(reveal: false) }
    }

    private var detectionSection: some View {
        Section("Call detection") {
            sourceToggle("Chrome calls", source: "chrome", detail: "Meet, Zoom, Teams, WhatsApp Web, Jitsi, Whereby, and approved custom domains")
            sourceToggle("Zoom desktop calls", source: "zoom", detail: "Best-effort prompt when Zoom uses the microphone")
            sourceToggle("WhatsApp desktop calls", source: "whatsapp", detail: "Best-effort prompt when WhatsApp uses the microphone")
            Text("Every detected call asks before recording. A detection never records automatically, and browser messages never contain page content or audio.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var extensionSection: some View {
        Section("Chrome extension") {
            LabeledContent("Status") {
                let connected = AppPreferences.chromeExtensionID != nil
                Text(connected ? "Connected to Chrome extension" : "Not connected")
                    .foregroundStyle(connected ? .green : .secondary)
            }
            Button("Prepare bundled extension…") { prepareExtension(reveal: true) }
            if let extensionFolder { Text(extensionFolder.path).font(.caption.monospaced()).textSelection(.enabled) }
            Text("1. In Chrome, open chrome://extensions and enable Developer mode. 2. Choose Load unpacked and select the folder above. 3. Copy the extension ID Chrome shows, paste it below, then connect it to Hall-e.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Chrome extension ID", text: $extensionID)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            HStack {
                Button("Connect extension") { connectExtension() }
                    .disabled(extensionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if FileManager.default.fileExists(atPath: ChromeNativeHostInstaller.chromeManifestURL.path) {
                    Text("Native host installed").font(.caption).foregroundStyle(.green)
                }
            }
            Text("The native host accepts messages only from this exact extension ID and queues them locally for Hall-e. It has no network access and never receives audio.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var customDomainsSection: some View {
        Section("Custom browser domains") {
            HStack {
                TextField("call.example.com", text: $newDomain).textFieldStyle(.roundedBorder)
                Button("Add") { addDomain() }.disabled(normalizedDomain(newDomain) == nil)
            }
            if customDomains.isEmpty {
                Text("No custom domains approved.").foregroundStyle(.secondary)
            } else {
                ForEach(customDomains, id: \.self) { domain in
                    HStack { Text(domain); Spacer(); Button("Remove", role: .destructive) { remove(domain) }.buttonStyle(.borderless) }
                }
            }
            Text("After adding a domain here, open the extension’s Options page in Chrome and approve the same exact domain there. Chrome shows its permission dialog before the extension can observe that domain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var permissionSection: some View {
        Section("Permission health") {
            permissionRow("Microphone", granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                          detail: "Required for every recording")
            HStack {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("System audio")
                    Text("macOS asks when Chrome, Zoom, or WhatsApp audio capture first starts").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("If app-audio capture is denied or unavailable, Hall-e keeps recording your microphone and marks that limitation on the session.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusSection: some View {
        if let statusMessage {
            Section { Text(statusMessage).font(.caption).foregroundStyle(statusMessage.hasPrefix("Ready") || statusMessage.hasPrefix("Connected") ? .green : .red) }
        }
    }

    private func sourceToggle(_ title: String, source: String, detail: String) -> some View {
        Toggle(title, isOn: Binding(get: { enabledSources.contains(source) }, set: { value in
            if value { enabledSources.insert(source) } else { enabledSources.remove(source) }
            AppPreferences.enabledCallSources = enabledSources
        }))
        .help(detail)
    }

    private func permissionRow(_ name: String, granted: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) { Text(name); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func prepareExtension(reveal: Bool) {
        do {
            let folder = try ChromeNativeHostInstaller.prepareExtension()
            extensionFolder = folder
            statusMessage = "Ready: load the local extension folder in Chrome."
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        } catch { statusMessage = error.localizedDescription }
    }

    private func connectExtension() {
        do {
            _ = try ChromeNativeHostInstaller.prepareExtension()
            try ChromeNativeHostInstaller.install(extensionID: extensionID)
            extensionID = AppPreferences.chromeExtensionID ?? extensionID
            statusMessage = "Connected: Chrome can now send local call signals to Hall-e."
        } catch { statusMessage = error.localizedDescription }
    }

    private func addDomain() {
        guard let domain = normalizedDomain(newDomain), !customDomains.contains(domain) else { return }
        customDomains.append(domain); customDomains.sort()
        AppPreferences.customCallDomains = customDomains
        newDomain = ""
    }

    private func remove(_ domain: String) {
        customDomains.removeAll { $0 == domain }
        AppPreferences.customCallDomains = customDomains
    }

    private func normalizedDomain(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        guard cleaned.contains("."), !cleaned.contains("*"), !cleaned.contains("@") else { return nil }
        return cleaned
    }
}
