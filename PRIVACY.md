# Privacy in Hall-e

Hall-e stores recordings, transcripts, project data, and its SQLite database on your Mac under `~/Library/Application Support/Hall-e`. Settings use macOS preferences. API keys and Google refresh tokens use macOS Keychain. A notes folder you select may sync using your own cloud drive.

## What leaves your Mac

- **Deepgram:** recording audio, only after you enable its audio permission. Hall-e requests model-improvement opt-out.
- **Speechmatics:** recording audio, only after its separate permission, supported region selection, and confirmation that Model Training is off. Batch data may be retained for up to seven days. Region changes require renewed consent.
- **Optional AI:** transcript text or selected project context goes to the AI integration you enable. Structured meeting reports have a separate consent setting.
- **Optional Google Calendar:** Hall-e retrieves calendar data with your connected account's read-only authorization.
- **Links:** Star and coffee/support links open a website in your browser. They never star or donate automatically.

Automatic transcription only chooses providers you configured and authorized. Silence monitoring uses Apple's local sound analysis. Speaker labels are anonymous voice clusters, not verified identities.

## Control and deletion

Disable a provider's audio toggle to stop new uploads. Revoking consent cannot retract data already sent. Use the provider dashboard for provider-side data controls, credit limits, and key revocation.

Recordings can be deleted in Hall-e. Locally cached provider responses, exported notes, and backups may remain separately. To remove all local Hall-e files, quit the app and remove its Application Support folder after backing up anything you want to keep; also remove the app's settings and its Keychain entries if you want a complete reset. Files in your chosen notes folder and provider-side jobs require separate deletion.

Only record and upload meetings when participants have received the notice or consent your situation requires.

Provider references: [Deepgram model improvement](https://developers.deepgram.com/docs/the-deepgram-model-improvement-partnership-program), [Speechmatics security and compliance](https://docs.speechmatics.com/administration/security-and-compliance).
