# Privacy in Hall-e

Hall-e stores recordings, transcripts, built-in meeting notes, project data, and its SQLite database on your Mac under `~/Library/Application Support/Hall-e`. Built-in notes use stable recording IDs in the separate `Meeting Notes` directory, so deleting an audio folder does not delete your writing. Settings use macOS preferences. API keys and Google refresh tokens use macOS Keychain. Exported files and a notes folder you select may sync using your own cloud drive.

## Local setup and recording

A new installation requires no Hall-e account. Supported Apple Speech transcription is explicitly constrained to on-device recognition; an unavailable local model produces a setup/retry state rather than an unapproved cloud upload. The optional eight-second setup check records a temporary microphone sample only after you start it. It never uses cloud transcription or enters the recording library, and Hall-e deletes it after completion or cancellation. A sample may remain in the system temporary directory after an unexpected app or system crash.

For online meetings, you explicitly choose the app whose audio to record. Its other playing tabs/windows may be included. A missing app or failed audio tap never silently expands capture to all system audio. Hall-e shows a microphone-only warning when meeting audio is unavailable.

## What leaves your Mac

- **Deepgram:** recording audio, only after you enable its audio permission. Hall-e requests model-improvement opt-out.
- **Speechmatics:** recording audio, only after its separate permission, supported region selection, and confirmation that Model Training is off. Batch data may be retained for up to seven days. Region changes require renewed consent.
- **Optional AI:** transcript text or selected project context goes to the AI integration you enable. Structured meeting reports have a separate consent setting.
- **Optional Google Calendar:** Hall-e retrieves calendar data with your connected account's read-only authorization.
- **Links:** Update/download, Star, and coffee/support links open a website in your browser. They never install, star, or donate automatically.

For new recordings, Automatic uses a configured, authorized cloud provider when available, otherwise Apple Speech locally. Selecting On this Mac keeps new transcription local even when cloud accounts exist. Previously accepted remote jobs retain their provider checkpoint to avoid duplicate submissions. Cloud processing requires the corresponding permission. Silence monitoring uses Apple's local sound analysis. Cloud speaker labels are anonymous voice clusters, not verified identities; local speech does not identify individual speakers.

## Control and deletion

Disable a provider's audio toggle to stop new uploads. Revoking consent cannot retract data already sent. Use the provider dashboard for provider-side data controls, credit limits, and key revocation.

Recordings can be deleted in Hall-e. Built-in meeting notes, locally cached provider responses, exported notes, and backups remain separately. Use the notes-folder button before deleting audio, or find built-in notes under `Meeting Notes` in Hall-e's Application Support folder. To remove all local Hall-e files, quit the app and remove its Application Support folder after backing up anything you want to keep; also remove the app's settings and its Keychain entries for a complete reset. Files in your chosen notes folder and provider-side jobs require separate deletion.

Only record and upload meetings when participants have received the notice or consent your situation requires.

Provider references: [Deepgram model improvement](https://developers.deepgram.com/docs/the-deepgram-model-improvement-partnership-program), [Speechmatics security and compliance](https://docs.speechmatics.com/administration/security-and-compliance).

## Calendars connected through macOS

With explicit Calendar permission, Hall-e imports only calendars you select from macOS EventKit. macOS handles Google/Microsoft/other account sign-in. Hall-e does not receive account passwords and does not read email or Teams chats. Imported event titles, times, locations, notes, attendees, responses, and meeting URLs are cached locally for the agenda, project organization, and reminders. Calendar event content may be processed by separately enabled optional AI features under their existing controls. Calendar permission is named Full Access by macOS; Hall-e performs no event writes.

Disconnecting removes the imported Mac-calendar cache, leaving source events and macOS accounts unchanged. Separately created recordings, notes, and project assignments remain. Revoking macOS Calendar permission clears imported cache on the next refresh or return to Hall-e. Do not connect the same calendar through both the macOS and advanced Google paths if you want to avoid possible duplicate meetings.
