<div align="center">

<img src="docs/assets/hall-e.png" width="128" alt="Hall-e smiling robot icon">

# Hall-e 🤖

### Your meetings, remembered. Your Mac, a little friendlier.

**Made with cariño in Chile 🇨🇱**

[Download](https://github.com/galdea/Hall-e/releases/latest) · [⭐ Star Hall-e](https://github.com/galdea/Hall-e) · [☕ Buy us a coffee](#support) · [Report a bug](https://github.com/galdea/Hall-e/issues/new/choose)

</div>

Hall-e is an open-source macOS assistant for recording meetings, turning conversations into readable transcripts, and keeping work organized by project.

The name borrows a little from **HAL**, from *2001: A Space Odyssey*, and a lot of heart from **WALL-E**. Smart, helpful, and nice. The airlock stays open. 🌱

## Install, add a key, press record

1. Download a ZIP from [Releases](https://github.com/galdea/Hall-e/releases). Choose **arm64** for Apple silicon or **x86_64** for Intel. Requires **macOS 14 or later**; capturing another app's audio requires **14.2+**.
2. Unzip and drag **Hall-e.app** into **Applications**. Open it and look for Hall-e in your menu bar.
3. Follow setup: allow your microphone, paste a **Deepgram** or **Speechmatics** API key, and allow that provider to transcribe your audio.
4. Click **Start recording**. Your audio and transcript appear in **Meetings & recordings → Recordings**.

No terminal, Google account, Obsidian, or separate AI subscription is required for the basic recording/transcription workflow. Internet access and usable provider credit are required for cloud transcription.

**Release signing:** archives marked `adhoc` are not Apple-notarized. macOS may block the first launch; after verifying the download, use **System Settings → Privacy & Security → Open Anyway** if offered. Managed Macs may disallow this. Archives explicitly marked `notarized` have completed Apple's checks. See [installation and release details](docs/release.md).

## Bring your own transcription key

| Provider | Set up | What Hall-e uses |
| --- | --- | --- |
| **Deepgram** | [Create an API key](https://console.deepgram.com/) | Nova-3 multilingual transcription with speaker diarization |
| **Speechmatics** | [Create an API key](https://portal.speechmatics.com/) | Melia 1 multilingual transcription with speaker diarization; select US or EU processing and confirm Model Training is off |

**We recommend setting up both.** In **Automatic** mode, Hall-e prefers Deepgram and switches to Speechmatics when Deepgram explicitly reports exhausted credit, provided both are configured and you enabled audio processing for each. Speechmatics also works by itself. Selecting a provider explicitly keeps that provider in control.

This works with eligible trial credit or paid accounts; providers set their own trial terms, balances, and prices. Hall-e doesn't create accounts or extend trials. It won't switch providers after an ambiguous upload or bypass your shared monthly spending guard. You can inspect the provider used in the transcript viewer. Recordings stay available when transcription needs attention.

The default **$25 monthly guard** estimates combined transcription spending in Hall-e; it is not a live provider balance or a billing cap. Change it in **Settings → Transcription** and set any account-level limits in your provider dashboard.

## Useful basics

- **Know who said what.** Read, search, copy, or export timestamps and anonymous **Speaker 1 / Speaker 2** labels. These distinguish voices, not people's identities. Speaker numbers belong to one recording and can be imperfect, especially with overlapping speech.
- **Keep meetings together.** Choose an existing project or create one while categorizing a meeting. Optionally apply it to future occurrences of a recurring meeting.
- **A gentle nudge.** With a calendar connected, get a gentle ring five minutes before a meeting.
- **Don't record an empty room forever.** After 20 seconds without detected speech, Hall-e asks whether to stop. It waits another 20 seconds, then stops if you don't respond. Change both timings or disable auto-stop in **Settings → Recording**. If audio monitoring is uncertain, Hall-e keeps recording.
- **Your workspace starts clean.** No preloaded personal projects. Recording, transcription, files, and privacy come first; integrations are optional.

## Add more when you need it

- **Google Calendar:** connect one or more accounts for your agenda and reminders. This currently requires importing your own Google Desktop OAuth client; [setup instructions](docs/calendar-setup.md).
- **Call capture:** supported desktop apps and the bundled Chrome extension can capture the other side of a call. Enable permissions and configure it in **Settings → Calls**. A microphone-only recording may not hear remote participants wearing headphones.
- **Notes:** choose an ordinary notes folder. Obsidian can open it too, but isn't required.
- **AI:** optional provider settings enable additional intelligence. The advanced structured-report integration has separate requirements; see [meeting pipeline](docs/operations/MEETING_PIPELINE.md). A transcription API key alone does not generate AI reports.
- **Apple Speech:** an optional on-device engine, selected explicitly in settings; availability depends on installed language support. It doesn't provide cloud-style speaker diarization.

## Your recordings are yours

API keys live in **macOS Keychain**. Audio, transcripts, and the local database live under `~/Library/Application Support/Hall-e`; notes may live in a folder you choose. Cloud audio processing is off until you enable a provider. Transcript-text AI processing has its own permission. Let everyone know when you record and send a meeting to a cloud service.

[Privacy details](PRIVACY.md) · [Report a security issue](SECURITY.md)

## Support

### ☕ Buy us a coffee

Hall-e runs on curiosity, cariño, and probably too much coffee. **A donation link is coming soon.** Until then, [give the project a star ⭐](https://github.com/galdea/Hall-e), share it with a friend, or help squash a bug. Stars help people find us; coffee will help us keep building. No nag screens, no features behind donations.

## Build with us

Install Xcode with a Swift 6 toolchain, then:

```sh
git clone https://github.com/galdea/Hall-e.git
cd Hall-e
make test
make app
open dist/Hall-e.app
```

`make release` creates an app ZIP and checksum. You don't need a personal signing certificate to build locally. For Developer ID signing, notarization, CI, and supported architectures, see [release documentation](docs/release.md).

Small improvements are welcome: clearer copy, better accessibility, Spanish/English polish, reliable audio capture, and thoughtful bug reports. [Contributing guide](CONTRIBUTING.md).

**[MIT licensed](LICENSE).** Built with SwiftUI, AppKit, and [GRDB](https://github.com/groue/GRDB.swift). See [third-party notices](THIRD_PARTY_NOTICES.md).

*From Chile, with a helpful little robot heart. 🇨🇱 🤖*
