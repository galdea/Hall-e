# Hall-e

> Meeting intelligence migration: the local Deepgram → OpenClaw/Gemini → JSON/Markdown/PDF pipeline is implemented but fail-closed until explicit consent, rotated credentials, agent setup, and A/B/backfill gates pass. See `docs/operations/MEETING_PIPELINE.md`.

A native macOS menu-bar work assistant: a unified agenda across multiple Google
Calendar accounts, meeting reminders, inline recording playback and transcripts,
automatic Obsidian notes, and a cited project assistant built from meetings, notes,
linked Codex sessions, and selected ChatGPT/WhatsApp exports. Local-first and private
by default.

SwiftUI + AppKit, built with Swift Package Manager (no Xcode required).

---

## Requirements

- macOS 14+ (built and tested on macOS 15.6, Apple Silicon).
- Command Line Tools for Xcode (`xcode-select --install`). Full Xcode is **not** needed.
- A Google Cloud project with the Calendar API enabled (see below).

## One-time setup

### 1. Toolchain workaround (this machine only)

This Mac's Command Line Tools install carries stale files that break SwiftPM. The
build scripts patch this automatically (`scripts/fix-toolchain.sh`), except for one
root-owned file that must be removed once:

```sh
sudo rm -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
```

(The current `bridging.modulemap` is byte-identical and stays.) A clean CLT reinstall
(`sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`) removes
the need for any of this.

### 2. Code-signing identity

Hall-e signs itself with a stable self-signed certificate so macOS keeps its
permissions (Notifications, Microphone) and Keychain items valid across rebuilds.

```sh
make cert          # creates the "Hall-e Dev" identity, prompt-free
```

`make cert` imports the key with an allow-all ACL (`security import -A`), so
`codesign` never shows a "wants to access key" dialog and no login password is
needed. The cert is self-signed and used only to sign Hall-e locally; TCC and
Keychain continuity rely on its stable designated requirement, not on trust.

### 3. Google Cloud OAuth client

1. Go to <https://console.cloud.google.com> → create a project (e.g. **Hall-e**).
2. **APIs & Services → Library →** enable **Google Calendar API**.
3. **APIs & Services → OAuth consent screen →** External. Add your Gmail accounts
   as test users, or publish (**In production**) so refresh tokens don't expire
   after 7 days. Scope needed: `.../auth/calendar.readonly` only.
4. **Credentials → Create Credentials → OAuth client ID → Desktop app →** download
   the JSON.
5. Launch Hall-e → **Settings → Accounts → Import client JSON**, then **Add Google
   Account** (repeat per account).

## Build & run

```sh
make run       # build + sign + install to /Applications + launch
make test      # run the unit test suite
make app       # build the signed .app into dist/ without installing
make clean
```

Always launch via `make run` (or Finder / `open`), **never** the bare executable —
macOS Notifications and permission prompts require a LaunchServices launch.

The icon appears in the menu bar (see "Notch note" below). Left-click for the
agenda, right-click for Refresh / Settings / Quit.

## Required macOS permissions

| Permission | When | Why |
|---|---|---|
| Notifications | first reminder is scheduled | 15-min meeting reminders |
| Microphone | first time you start a recording | meeting audio capture |
| Speech Recognition | first transcription | on-device transcription |

All are requested only when the feature is first used. Calendar access is via Google
OAuth (browser), not a macOS permission.

## Browser and desktop call capture

Hall-e can offer local recording for supported Chrome calls (Google Meet, Zoom,
Teams, WhatsApp Web, Jitsi, and Whereby) and best-effort Zoom/WhatsApp desktop
calls. It always asks before capture, and it never creates or changes a Google
Calendar event for a call it discovers outside the calendar.

Open **Settings → Browser & Calls** to prepare the bundled Chrome extension, load
it from `chrome://extensions`, and connect its displayed ID to Hall-e. The native
helper accepts messages only from that exact extension ID, queues them locally, and
does not receive audio or use the network. Add a custom domain in Hall-e and then
approve that same host from the extension's Options page.

## Privacy

- Local-first: calendar cache, notes, recordings, and transcripts stay on disk.
- Google refresh tokens and LLM API keys live only in the macOS Keychain — never in
  UserDefaults, files, logs, or notes.
- Read-only calendar access (`calendar.readonly`).
- AI features are **off** until you configure a provider. Cloud transcript
  and imported-conversation processing is **off** until you explicitly enable it.
- Join-triggered calendar recording is opt-in and visibly indicated; ordinary calendar
  events never start recording on their own, and manual recordings retain consent.
- Codex indexing is opt-in per project folder and excludes system prompts, hidden
  reasoning, tool output, credentials, and unrelated working directories.
- ChatGPT and WhatsApp context is imported only from files and conversations you select.

## Notch note (crowded menu bar)

On a MacBook with a notch and a full menu bar, macOS can hide the newest status
item behind the notch. If you don't see Hall-e's icon, free a menu-bar slot (quit an
unused item, or ⌘-drag one off) or use a menu-bar manager like
[Ice](https://github.com/jordanbaird/Ice). Hall-e itself is running and correct.

## What works today (core platform)

- Menu-bar app (agent-style, no Dock icon), polished popover, 10-section Settings.
- Multiple Google accounts via OAuth 2.0 PKCE + loopback; tokens in Keychain.
- Windowed calendar sync (today −1d … +7d) with per-account error isolation,
  backoff, and offline tolerance.
- Cross-account **deduplication** (iCalUID + instance start, fuzzy fallback) so a
  meeting invited to two accounts shows once with both source dots.
- Hourly agenda with All-day / Now / Next sections, current-meeting highlight, join
  buttons, status styling, calm empty states.
- 15-minute local notifications with a ledger (no duplicate reminders across
  resyncs), actions (Join / Open agenda / Prepare note / Snooze), and cancel-on-
  change.
- Periodic + wake + network-restored refresh; launch-at-login.
- Completed calendar events expose inline recording playback and searchable transcripts.
- Optional exact calendar-end auto-stop, WhatsApp call-end detection, and a 20-second
  silence prompt that never stops without confirmation.
- Data-rich Projects workspace with health, status, activity, risks, next steps,
  suggested agendas, linked-source freshness, and cited assistant conversations.
- Selective ChatGPT export import, incremental WhatsApp chat import, and project-folder-
  scoped Codex session indexing.

## In progress / roadmap

- Obsidian vault integration (safe, non-destructive meeting notes + project indexes).
- Deterministic + LLM project classifier for your projects.
- AI Orchestrator (OpenAI-compatible, Anthropic, Gemini, Ollama/LM Studio) with
  Keychain-stored keys.
- Broader media import and richer multi-speaker transcript editing.
- Apple Calendar (EventKit) as an optional source; morning brief / end-of-day digest.

## Architecture

```
Sources/HallE/
  main.swift, AppDelegate.swift        app bootstrap (LSUIElement agent)
  Support/                             AppState, Keychain, paths, logging, launch-at-login
  Models/ + Persistence/               GRDB records + migrations (halle.sqlite)
  Google/                              OAuth (PKCE + loopback), token store, REST client
  Sync/                                windowed sync, dedup, refresh scheduler, event mapping
  Notifications/                       planner (pure) + scheduler + delegate
  MenuBar/ + Agenda/                   status item, popover, timeline, rows
  Settings/                            10-tab settings shell
  FeatureHooks/                        seams for Obsidian/recording (feature phases)
```

Tests use Swift Testing (`swift test`): dedup, timeline, notification planner, PKCE,
database.
