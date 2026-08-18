# Current Architecture

Status: Implementation verified locally 2026-08-09; activation and migration remain gated

## Runtime

Hall-E is a single native macOS process. `RecordingService` captures audio and calls `RecordingCoordinator` when a recording ends. Each recording owns a folder containing audio, `session.json`, and `transcript.json`. `TranscriptionJob` persists retry/checkpoint state so interrupted work resumes after launch.

`RecordingCoordinator` now resolves Deepgram Nova-3 multilingual when cloud-audio consent and a rotated Keychain credential are available, while preserving the existing local engines during the staged migration. Deepgram uses whole-file prerecorded upload, diarization v2, durable retry/ambiguous-billing state, a monthly spend guard, and fail-closed transcript promotion.

After a validated transcript, an independent durable briefing job can invoke the tool-less `halle-reports` OpenClaw agent with the Gemini-only model allowlist. The canonical evidence-backed briefing is validated before deterministic JSON, Markdown, PDF, and Obsidian marker output are promoted. Reporting failure does not change transcript success.

## Persistence

- GRDB stores calendar/project/search records.
- Recording folders are the source of truth for audio, transcript, and per-recording job state.
- Obsidian is the human-readable project/meeting record.
- API keys and OAuth refresh tokens use macOS Keychain.
- Project definitions use `aliases.json`; briefing design profiles and copied local assets are persisted independently of source repositories.

## Existing strengths to retain

- Single process and no distributed infrastructure.
- Durable per-session retries.
- Atomic local writes.
- Raw audio retained as source of truth.
- Explicit engine selection and no silent fallback.
- Hall-E-managed marker blocks preserve unrelated Obsidian content.

## Activation and migration gates still open

- Rotate the Deepgram credential disclosed in chat and enter it through Hall-E Settings.
- Explicitly approve and create the production `halle-reports` OpenClaw agent configuration.
- Record separate cloud-audio and cloud-text consent before provider calls.
- Pass the four-recording A/B gate and explicitly authorize the exact historical manifest.
- Accept full reconciliation and create rollback artifacts before any Whisper removal.
