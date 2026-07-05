# Hall-e

A native macOS menu-bar work assistant: a unified hourly agenda across multiple
Google Calendar accounts, 15-minute meeting reminders, automatic Obsidian meeting
notes, deterministic + LLM-assisted project classification, and manual meeting
recording with on-device transcription. Local-first and private by default.

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
make cert          # creates the "Hall-e Dev" identity (or do it in Keychain Access)
```

Then authorize `codesign` to use the key **once**, so builds don't prompt:

```sh
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "<your login password>" ~/Library/Keychains/login.keychain-db
```

(Alternatively, the first build shows a "codesign wants to access key" dialog —
click **Always Allow**.)

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

## Privacy

- Local-first: calendar cache, notes, recordings, and transcripts stay on disk.
- Google refresh tokens and LLM API keys live only in the macOS Keychain — never in
  UserDefaults, files, logs, or notes.
- Read-only calendar access (`calendar.readonly`).
- AI features are **off** until you configure a provider. Cloud transcript
  processing is **off** until you explicitly enable it.
- Recording is always user-initiated and visibly indicated — never automatic.

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

## In progress / roadmap

- Obsidian vault integration (safe, non-destructive meeting notes + project indexes).
- Deterministic + LLM project classifier for your projects.
- AI Orchestrator (OpenAI-compatible, Anthropic, Gemini, Ollama/LM Studio) with
  Keychain-stored keys.
- Manual mic recording + on-device transcription (SFSpeechRecognizer), then system
  audio via Core Audio taps.
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
