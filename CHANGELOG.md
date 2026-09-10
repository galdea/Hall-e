# Changelog

## macOS 0.3.2 / Windows preview 0.1.1 — Recording reliability

- macOS: prevent delayed processing from recreating deleted recordings, protect active processing from deletion, and cancel deleted recordings' scheduled retries.
- macOS: clear completed/failed recording ownership and require durable Speechmatics submission/job-ID checkpoints before continuing paid work.
- Windows: retain capture ownership after warnings, rejected stop requests, and stop/rollback timeouts, allowing a safe Stop retry.
- Windows: recover interrupted recordings independently so damaged audio cannot block startup; retain original files and cloud job checkpoints.
- Windows: merge metadata updates atomically, ignore stale meeting-selection loads, release completed capture UI state even when metadata saving fails, and time out stalled transcription response bodies.
- Releases: package Windows from a clean payload, derive its version from shared build properties, and verify installation, update, uninstallation, and the extracted portable ZIP before publishing.
- Download page: verify published installers and checksums before updating links, version labels, and setup links together.

## 0.2.2 — Your calendars, including Teams invitations

- First-run account setup uses macOS Internet Accounts for Google, Microsoft Exchange/Outlook, and other calendars available in Apple Calendar.
- Explicit calendar selection, refresh, permission recovery, and local-cache disconnect controls.
- Import event details and invitation responses; recognize Teams meeting links, including the newer Teams domain.
- Keep advanced direct Google OAuth available; no email or Teams-chat access.

## 0.2.1 — Bring your own key, step by step

- First-run setup explains personal provider accounts and eligible trial credit.
- Direct signup and key-creation guides, explicit Paste buttons, and a configuration checklist help users connect their own keys.
- Spending controls now sit in a shared section for both providers.
- No shared API credentials; personal accounts are not a public release prerequisite.

## 0.2.0 — Public app preparation

- New first-run setup for microphone and Deepgram/Speechmatics API keys.
- Automatic, separately authorized Speechmatics fallback after Deepgram credit exhaustion; durable jobs resume without duplicate submission.
- Anonymous speaker labels and timestamps in the transcript viewer, copied text, and text exports.
- Empty fresh workspaces, a calendar-independent home screen, and simpler settings/project navigation.
- Five-minute gentle reminders, meeting-to-project assignment, and configurable 20+20-second silence stopping.
- Original app icon, MIT license, contribution/privacy guidance, GitHub star and coffee-support links.
- Architecture-specific release archives, checksums, and optional Developer ID notarization workflow.

Public-launch checklist: configure the donation destination, validate real provider calls with test audio, complete a fresh-Mac permissions/install check, and publish a reviewed release from a public repository. Ad-hoc artifacts are not notarized.
