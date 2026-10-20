# Hall-e for Android

The Android companion is a local agenda and reminder app. It reads chosen calendars through Android's `CalendarContract`, displays today's meetings, offers meeting links where a supported conferencing URL is present, and lets the user organize meetings into local projects and keep/share Markdown notes. Projects, assignments, notes, preferences, and reminder identifiers are stored on the phone. There is no account, backend connection, or synchronization with Hall-e for Mac.

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

The app declares calendar read, notifications, exact alarms, and boot-completed permissions. It does not request calendar write access, microphone, contacts, location, or network access. Calendar data and user-created notes remain local; sharing a note is an explicit Android share-sheet action. Meeting URLs are limited to recognized conferencing hosts and open in an external app or browser. Hall-e does not record meetings or audio on Android.
