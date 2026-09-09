# Current architecture — public app preparation

Hall-e is a SwiftUI/AppKit macOS 14+ menu-bar app, packaged by SwiftPM with a separate Chrome native-message host. GRDB stores calendar and workspace data. Credentials use Keychain; projects start empty on a fresh installation.

## Recording and transcription

Audio is captured and checkpointed locally, then transcribed after recording. Silence handling uses on-device SoundAnalysis with configurable 20-second detection and 20-second confirmation defaults. Unknown or stale audio evidence pauses automatic stopping.

Automatic transcription prefers configured, consented Deepgram Nova-3. Speechmatics Melia 1 can work alone or take over after a definite Deepgram credit-exhaustion response. Other failures do not cause cross-provider fallback. Explicit provider selection never triggers fallback. The shared estimated monthly spending guard remains authoritative across providers.

Speechmatics requires its own Keychain key, US/EU region selection, Model Training-off confirmation, and region-specific audio consent. Its create/poll workflow persists a remote job ID to resume without re-uploading; ambiguous submission requires review. Melia 1 is not offered in Australia. Both providers normalize anonymous speaker labels into the existing transcript model. The viewer and exports preserve labels and timestamps.

## Optional integrations

Google Calendar uses a user-imported Desktop OAuth client and read-only access. Notes can use a normal folder or an Obsidian vault. AI providers and the separate OpenClaw structured-report pipeline are optional and have their own processing controls. No integration is required to record audio locally.

## Distribution

The release workflow tests/builds Apple silicon and Intel archives and prepares a draft GitHub Release for version tags. Ad-hoc packages require no local signing identity; Developer ID signing and notarization are optional, explicitly configured steps. App resources, licenses, icon, notification sound, and browser extension ship inside the app.

The repository must be public and the release published before anonymous downloads work. A paid-provider smoke test, clean-Mac permissions check, and notarization remain separate from unit-test/build success. See [release documentation](../release.md).
