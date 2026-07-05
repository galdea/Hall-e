import Foundation

/// Seams that later feature phases implement (Obsidian, recording).
/// The agenda/notification UI calls these; the default is a safe no-op so the
/// core app runs before those phases land.
@MainActor
protocol FeatureHooks: AnyObject {
    func prepareNote(for event: UnifiedEvent)
    func openInObsidian(_ event: UnifiedEvent)
    func startRecording(for event: UnifiedEvent)
    var canOpenObsidian: Bool { get }
}

@MainActor
final class NoopFeatureHooks: FeatureHooks {
    func prepareNote(for event: UnifiedEvent) { Log.app.info("prepareNote (noop)") }
    func openInObsidian(_ event: UnifiedEvent) { Log.app.info("openInObsidian (noop)") }
    func startRecording(for event: UnifiedEvent) { Log.app.info("startRecording (noop)") }
    var canOpenObsidian: Bool { false }
}

/// Global hook registry; feature phases replace `current` at launch.
@MainActor
enum Features {
    static var current: FeatureHooks = NoopFeatureHooks()
}
