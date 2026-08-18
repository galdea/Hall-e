import SwiftUI
import AppKit

/// Drives the ADR 0004 migration gates in order. Each step is a separate,
/// explicit act: nothing here runs on launch, and no step is skipped by a
/// button being pressed out of order — the controller re-validates every gate.
@Observable @MainActor final class DeepgramMigrationModel {
    var manifestURL: URL?
    var manifest: HistoricalBackfillManifest?
    var selections: [DeepgramSampleSelection] = []
    var sampleReport: DeepgramABSampleReport?
    var reconciliation: HistoricalBackfillReconciliation?
    var acknowledgeDrift = false
    var status: String?
    var busy: String?

    var keyStored: Bool { KeychainStore.exists(account: KeychainStore.deepgramTranscriptionAccount) }
    var audioConsent: Bool { AppPreferences.allowCloudAudioTranscription }
    var reportConsent: Bool { AppPreferences.allowCloudTranscriptReports }
    var engineIsDeepgram: Bool {
        AppPreferences.transcriptionEngine == .deepgram || AppPreferences.transcriptionEngine == .auto
    }
    var drift: String? { manifest.flatMap(HistoricalBackfillController.baselineDrift) }
    var samplesApproved: Bool { manifest?.sampleReportsApprovedAt != nil }

    /// Gate 2. Hashes local artifacts only; sends nothing.
    func generateManifest() {
        do {
            let url = try HistoricalBackfillController.makeManifest()
            manifestURL = url
            manifest = try HistoricalBackfillController.loadManifest(url)
            acknowledgeDrift = false
            status = manifest.map {
                "\($0.items.count) recordings · \(Int($0.items.reduce(0) { $0 + $1.durationSeconds } / 60)) min · $\(String(format: "%.2f", $0.estimatedCostUSD)) estimated"
            }
        } catch { status = error.localizedDescription }
    }

    func selectSamples() {
        selections = DeepgramABSampleRunner.selectRepresentatives()
        status = selections.isEmpty
            ? "No recording has readable audio to sample."
            : "\(selections.count) representative recordings selected · $\(String(format: "%.2f", selections.reduce(0) { $0 + DeepgramConfiguration.estimatedCostUSD(duration: $1.durationSeconds) })) estimated"
    }

    /// Gate 4. Transcribes the samples into a review folder. It never replaces an
    /// active transcript, so a rejected sample leaves everything untouched.
    func runSamples() async {
        guard !selections.isEmpty else { status = "Select representative recordings first."; return }
        busy = "Transcribing \(selections.count) A/B samples with Deepgram…"
        defer { busy = nil }
        do {
            let report = try await DeepgramABSampleRunner.run(selections: selections)
            sampleReport = report
            let failed = report.outcomes.filter { !$0.succeeded }
            status = failed.isEmpty
                ? "\(report.outcomes.count) samples written · $\(String(format: "%.2f", report.billedEstimateUSD)) billed. Review comparison.md in each folder."
                : "\(report.outcomes.count - failed.count) succeeded, \(failed.count) failed: \(failed.compactMap(\.error).joined(separator: " / "))"
        } catch { status = error.localizedDescription }
    }

    /// Gate 5. Records that a person read the comparisons and accepted them.
    func acceptSamples() {
        guard let manifestURL, let report = sampleReport else {
            status = "Generate a manifest and run the A/B samples first."; return
        }
        do {
            try HistoricalBackfillController.recordABApproval(manifestURL: manifestURL,
                                                              sessionIDs: report.acceptedSessionIDs,
                                                              reportsApproved: true)
            manifest = try HistoricalBackfillController.loadManifest(manifestURL)
            status = "A/B acceptance recorded for \(report.acceptedSessionIDs.count) recordings."
        } catch { status = error.localizedDescription }
    }

    /// Gates 6–8. Serial, checkpointed after every recording, and it reuses any
    /// cached A/B response so a sampled recording is not paid for twice.
    func runBackfill() async {
        guard let manifestURL, let manifest else { status = "Generate a manifest first."; return }
        busy = "Re-transcribing \(manifest.items.count) recordings with Deepgram…"
        defer { busy = nil }
        do {
            let authorization = HistoricalBackfillController.makeAuthorization(
                for: manifest, approvedSpendUSD: manifest.estimatedCostUSD,
                samplesAccepted: manifest.sampleReportsApprovedAt != nil,
                acknowledgedBaselineDrift: acknowledgeDrift)
            try await HistoricalBackfillController.run(manifestURL: manifestURL, authorization: authorization)
            let reloaded = try HistoricalBackfillController.loadManifest(manifestURL)
            self.manifest = reloaded
            let value = HistoricalBackfillController.reconcile(reloaded)
            reconciliation = value
            status = "Completed \(value.completed)/\(value.expected) · failed \(value.failed) · ambiguous \(value.ambiguous) · skipped \(value.skipped)"
        } catch { status = error.localizedDescription }
    }
}

struct DeepgramMigrationSection: View {
    let model: DeepgramMigrationModel

    var body: some View {
        Section("Deepgram historical migration") {
            readiness

            LabeledContent("1 · Manifest") {
                Button("Generate (zero network)") { model.generateManifest() }
            }
            if let drift = model.drift {
                Toggle(isOn: Binding(get: { model.acknowledgeDrift }, set: { model.acknowledgeDrift = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Acknowledge corpus drift from the ADR baseline")
                        Text(drift).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            LabeledContent("2 · A/B samples") {
                HStack {
                    Button("Select") { model.selectSamples() }
                    Button("Transcribe") { Task { await model.runSamples() } }
                        .disabled(model.selections.isEmpty || model.busy != nil)
                }
            }
            ForEach(model.selections) { selection in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(selection.category.displayName) · \(String(format: "%.0f", selection.durationSeconds / 60)) min")
                        .font(.caption)
                    Text(selection.slug).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let report = model.sampleReport {
                ForEach(report.outcomes) { outcome in
                    HStack(spacing: 6) {
                        Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(outcome.succeeded ? .green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(outcome.category.displayName).font(.caption)
                            Text(outcome.succeeded
                                 ? "\(outcome.deepgramSegmentCount) utterances · \(outcome.distinctSpeakerCount) speakers · was \(outcome.priorSegmentCount) segments, 0 speakers"
                                 : (outcome.error ?? "failed"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if outcome.succeeded {
                            Button("Review") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: outcome.reviewFolderPath))
                            }.buttonStyle(.link)
                        }
                    }
                }
            }

            LabeledContent("3 · Acceptance") {
                Button(model.samplesApproved ? "Recorded" : "Accept samples & reports") { model.acceptSamples() }
                    .disabled(model.sampleReport == nil)
            }

            LabeledContent("4 · Backfill") {
                Button(backfillTitle) { Task { await model.runBackfill() } }
                    .disabled(model.manifest == nil || model.busy != nil)
            }

            if let busy = model.busy {
                HStack { ProgressView().controlSize(.small); Text(busy).font(.caption) }
            }
            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Button("Reveal migration folder") { NSWorkspace.shared.open(AppPaths.backfillDirectory) }

            Text("The manifest hashes local artifacts only. Uploads additionally require an exact-manifest authorization, accepted A/B samples, report approval, and the consent and spend gates. Every recording's prior transcript and note are snapshotted to its `pre-deepgram/` folder before promotion.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var backfillTitle: String {
        guard let manifest = model.manifest else { return "Run backfill" }
        return "Run backfill · \(manifest.items.count) · $\(String(format: "%.2f", manifest.estimatedCostUSD))"
    }

    @ViewBuilder
    private var readiness: some View {
        VStack(alignment: .leading, spacing: 3) {
            requirement("Deepgram key in Keychain", model.keyStored)
            requirement("Cloud audio consent", model.audioConsent)
            requirement("Cloud transcript-text consent (reports)", model.reportConsent)
            requirement("Engine will resolve to Deepgram", model.engineIsDeepgram && model.keyStored && model.audioConsent)
        }
    }

    private func requirement(_ label: String, _ satisfied: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: satisfied ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(satisfied ? .green : .secondary)
            Text(label).font(.caption)
        }
    }
}
