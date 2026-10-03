# Mock QA and reversible installation plan

## Current status and native interface blocker

Use an isolated development checkout and the fixture preview for these checks. Record the actual installed application identity, version and hash locally before any approved replacement; machine-specific installation evidence stays outside the public repository.

The original native route was mcp__cua_repl.js, invoking cua.getApp("cl.gabriel.hall-e.calendar-preview"). The binding stalled despite a requested 30-second timeout, then was aborted after approximately 4,990 seconds. It returned no permission-denial message and performed no subsequent click. In the recovery turn, the advertised tool registry has no native CUA, computer, browser or screenshot interface. The only outer-tool proxy requires an unavailable turn_token; no token or wire name was guessed. This is a stalled/missing interface, not evidence that macOS denied access. No second unbounded native call was attempted.

The supported fallback is the app's own offscreen NSHostingView/AppKit renderer with isolated fixtures. It proves visual layout and displayed state, not physical button activation. Mocked calendar transport/ledger tests prove duplicate-click/restart deduplication; date/month and preparation-policy tests prove navigation/timing/cancellation state. Mouse/keyboard activation of Cancel, date cells, month arrows and popup Dismiss remains a user-assisted native check.

## Minimal user-assisted mock check

Use only the separately identified Hall-E Calendar Preview.app in this task's calendar-reference folder. The debug package identity itself forces fixture mode, including termination, even when opened from Finder without an environment flag. It bypasses production AppState/database, recording recovery, OAuth, provider jobs and timers. Its calendars, saves, classes and preparation popup are synthetic. Do not open the normal installed Hall-E to perform these checks.

1. Open the preview. Select October 7 and October 12: the selected-day details should show the no-class annotation and no visible class event. Ordinary Monday/Wednesday/Thursday dates should show purple weekly class cards. These annotations do not cancel external events.
2. Use the month arrows to reach November and return. The empty-state text should say that no visible events do not confirm availability. Select another date and confirm the detail date changes.
3. Select Add event, then Cancel. The sheet should close without a new event. Reopen it, choose Preview calendar (mock), enter an event, and save. Its selected-day list should show one item. The sheet disables the Save action while saving; repeated requests with the same identity are already covered by ledger tests.
4. Select Preparation fixture, then Dismiss. The separate mock popup should close. Repeat with Snooze 2 min or Open meeting: these fixture actions close the popup and do not start timers, open a real workspace or call providers.
5. Close the popup, then quit the preview with Command-Q. The production Hall-E application and recordings should remain unchanged.

Report only a failed step or the five-step pass. These steps require no account connection or new privacy permission. Broader UI, fresh-profile empty calendars and editor layout also have saved fixture renders.

## Installation sequence — prepared, not executed

1. Finish the above mock checks and the existing release/security/migration gates for one exact candidate commit. Use scripts/build.sh and scripts/verify-release.sh in the isolated checkout after choosing a candidate version/build/signing mode. The current evidence is a debug build with targeted tests, not a signed/notarized release. Coordinate disk space before a release build. Honor docs/ci-policy.md and required hosted release gates; do not trigger paid Actions or publish.
2. Prepare a private, fresh rollback directory at the installation time. Record the current app version, bundle identity, executable hash and strict signature check. Make a verified APFS clone of the complete installed app before changing it. Preserve its entitlements, resources and extended attributes. Do not move or delete the original until the candidate is verified.
3. With Hall-E safely quit and no active recording, make consistent fresh snapshots of its SQLite database (including WAL through SQLite backup), current non-secret preferences, aliases and current recording/session/vault state. Keep paths, ownership, hashes and recording/transcript counts in a manifest. Existing historical backups are evidence, not a substitute for this fresh snapshot. Do not export Keychain secrets, restore trashed audio, or replace existing transcripts. Avoid an unverified large full-data copy; reserve and verify the required space or use an authorized APFS clone/snapshot.
4. Before the first production launch, explicitly review the startup effects below. The current candidate has no production-wide pause switch. A silent/no-provider first production launch therefore requires a reviewed startup-quiescence change or explicit approval for the existing startup work. The safe fixture launch is not a production migration smoke test. Do not assume installation approval authorizes a paid backlog.
5. Present the exact candidate path, commit, version/build, hash/signature, backup manifest, startup mode and rollback path for user approval. Replace /Applications/Hall-e.app only after approval. Retain the previous app and data snapshots until acceptance; do not change login items, Keychain entries or OAuth grants as part of the binary replacement.
6. After the controlled startup is separately approved, verify the actual four tabs, existing settings/calendar selections, preserved transcript/actions counts and existing project assignments. A real event save requires its own explicit destination/draft approval and official writing grant. Do not create attendees, invitations or recurrence exceptions as a smoke test without approval.

Do not run scripts/smoke-install.sh on this Mac. It is restricted to disposable GitHub macOS runners and intentionally clears/restores a fresh test profile. Do not fake its environment guards.

## Existing production startup side effects

AppDelegate initializes the production database and applies v7 schema additions. It configures notifications and can request authorization when onboarding and notifications are enabled. RecordingLibrary.migrateFlatLayoutOnce can move/rename legacy recording folders; recovery can reconcile sessions, enqueue legacy/transcription retries, and resume durable jobs. Those transcription jobs can upload audio and spend provider credit under existing consent/settings. The default briefing path now marks local-agent review as required instead of invoking OpenClaw automatically.

Vault indexing updates disposable search/action rows and normally posts project-knowledge changes. Linked Codex source import runs. RefreshScheduler starts calendar/token reads shortly after launch, then optional AI classification; project intelligence can schedule provider refreshes. Call detection and the credit watchdog start, and the new local preparation timer starts. Existing auto-record settings remain effective. These are existing normal startup behaviors, and a binary replacement does not neutralize them. No such production startup was performed during fixture QA.

## Rollback

Safely stop the candidate, preserve a new snapshot of any state created since installation, and restore the verified previous app bundle to its original path. Verify its version/hash/signature before launching. Do not assume the older binary accepts the v7 schema; choose a verified database rollback or compatibility path first. Data restoration requires review so new legitimate recordings, transcripts, commitments and user edits are retained. Do not restore missing/trashed audio or delete the candidate's new artifacts indiscriminately.

A binary rollback does not revoke a newly granted Google writing scope and does not undo a saved external event. Review those separately with the user; do not change permissions or remove an external event automatically. Rollback is ready only after both the binary and data plan have been verified.
