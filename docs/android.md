# Hall-e for Android

The Android companion is an agenda, reminder, and optional local recording app. It reads chosen calendars through Android's `CalendarContract`, displays today's meetings, offers meeting links where a supported conferencing URL is present, and lets the user organize meetings into local projects and keep/share Markdown notes. Projects, assignments, notes, recordings, preferences, and reminder identifiers are stored on the phone. Pairing is optional and shares selected client-encrypted meeting details plus coordination metadata through the Hall-e coordinator with paired Hall-e devices, including Mac. It does not automatically synchronize full calendars, notes, projects, or audio, and has no Hall-e account system. This document describes the 0.2.0/code 2 candidate; the existing 0.1.0/code 1 internal-track release predates recording and shared workspaces.

## Requirements and build

- Android Studio / Android Gradle Plugin 9.0.0, Gradle 9.1.0, and JDK 17.
- Android SDK Platform 36 (the app's minimum supported Android version is API 31).
- The Gradle bootstrap downloads the pinned Gradle 9.1.0 distribution and verifies its SHA-256 before use. On macOS/Linux, run `./gradlew test` or `./gradlew assembleDebug` from this directory. Android Studio can open this directory directly.
- The SDK path may be supplied through `ANDROID_HOME` or `ANDROID_SDK_ROOT`, or configured locally by Android Studio. `local.properties` is ignored.
- For a signed release, set `ANDROID_KEYSTORE`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD`. A release task fails if any value is missing. Keep keystores and passwords out of source control.

## Calendar access and reminders

Hall-e requests read-only calendar permission at runtime. It initially selects the calendars available on the device; the user can change that selection in Settings. It reads occurrences from `CalendarContract.Instances`, and excludes canceled or declined events. All-day entries appear in the agenda but do not trigger alerts. Occurrence identifiers include the calendar, event, and start time so recurring meetings can be scheduled separately. Changes to device time, timezone, date, boot state, or calendar provider request a reminder refresh. The app schedules the next 30 days of upcoming reminders and refreshes them when opened.

Reminder timing can be set to meeting start, 1, 5, 10, 15, or 30 minutes before, or a custom interval from 1 to 1440 minutes. Android notification permission and exact-alarm access are controlled by the operating system and may be denied or revoked. Without notification permission no notification is shown; without exact-alarm access Android may deliver a reminder later than requested, subject to system power restrictions. The app does not use a persistent foreground service to promise delivery.

The morning overview is shown on the first app open from 04:00 until noon local time on a given date, if calendar access is available and the feature is enabled. It is not a guaranteed background notification: Android may not start the app before the user unlocks or opens it, especially after a reboot. The overview is generated only when the app opens during that local-time window.

## Privacy

The app requests calendar read, notifications, exact alarms, boot-completed, microphone, foreground microphone service, and network permissions. It does not request calendar write access, contacts, or location. Calendar data, event IDs, and notes remain local; sharing a note is an explicit Android share-sheet action. Meeting URLs are limited to recognized conferencing hosts and open in an external app or browser.

Android recording is optional and starts only after a visible user action and microphone permission. Audio files remain in app-private storage on the phone; the shared-session coordinator never receives audio. Without pairing, meeting details and recordings stay on that phone. If the user explicitly creates or joins a shared workspace, Hall-e encrypts a meeting title and optional project name, meeting URL, and scheduled times on the device before sending them to the allowlisted coordinator. The coordinator also stores opaque workspace/device/session IDs, display-only device names, session ciphertext, segment timestamps/status, and recording-lease metadata. It does not receive the calendar event ID, calendar contents, or encryption key. Credentials and the workspace key are encrypted with an Android Keystore key.

Shared recording is exclusive across the workspace. A phone must publish the encrypted session and obtain a short-lived lease before it starts its microphone; it renews while recording and stops locally if renewal fails or another device requests handoff. A handoff is only a prompt to the current phone. It cannot start recording on the target phone. The target user must separately choose to record and grant microphone access.
