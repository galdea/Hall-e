# Google Play Console: App content and Data Safety

Source-backed preparation for the Android release. This records product behavior
and recommended answers; owner-only declarations are marked for confirmation.
Do not treat this as a legal attestation.

## App details

- **Release application ID:** `app.halle.companion` (`android/app/build.gradle.kts`,
  `defaultConfig.applicationId`). The debug build uses `app.halle.companion.preview`
  and must not be uploaded.
- **Existing internal-track release:** `versionName` `0.1.0`, `versionCode` `1`.
  The current source candidate is `0.2.0`, `versionCode` `2`, per
  `android/app/build.gradle.kts`. The updated recording and shared-workspace
  disclosures apply to that candidate. Its signed AAB was uploaded and saved as
  internal-track draft release 2. Play finished processing it and lists code 2
  on the release-review screen. It is not published; complete the remaining
  physical pairing/handoff QA before promoting it.
- **Minimum Android:** API 31 (Android 12); **target/compile:** API 36.
- **Suggested category:** Productivity, matching the listing draft.
- **Ads:** No ads are implemented and there is no ads SDK in the app dependencies.
  Answer **No** if the release candidate remains unchanged.
- **Account/app access:** The app has no sign-in, Hall-e account, or gated screen;
  no reviewer credentials are needed.
- **Support and privacy URLs:** Listing draft proposes the GitHub issue form for
  support and `https://hall-e.pages.dev/android-privacy.html` for privacy. Confirm
  the support destination is owner-approved and durable before publication.

## Data Safety: evidence and candidate responses

The manifest declares `INTERNET`, `READ_CALENDAR`, `POST_NOTIFICATIONS`,
`SCHEDULE_EXACT_ALARM`, `RECEIVE_BOOT_COMPLETED`, `RECORD_AUDIO`,
`FOREGROUND_SERVICE`, and `FOREGROUND_SERVICE_MICROPHONE`. Calendar access is
read-only through Android's provider. Microphone use is optional and only begins
after a visible user action. The production dependency is AndroidX Core KTX;
JUnit is test-only. There is no analytics, advertising, or crash-reporting SDK.

Calendar data used on-device includes event and calendar IDs, event start/end,
title, location, all-day status, event status, description/custom URI (to find
supported meeting links), and attendee email/status (to exclude a declined
invitation matching the calendar account). `LocalStore` persists selected
calendar IDs, projects and meeting assignments, Markdown notes, reminder
preferences, morning-summary date, and reminder/delivery occurrence identifiers
in app-private SharedPreferences. It does not copy full event records to a
separate database or send them to a Hall-e server. Optional shared workspaces
send client-encrypted meeting titles, optional project names and supported
meeting URLs, and scheduled times, plus device/session/segment IDs, device
display names, segment timestamps/status, and lease metadata to the configured
coordinator. Calendar event IDs, full calendar records, audio, and the workspace
encryption key are not sent. Recordings stay in app-private storage. This is
selected meeting-detail coordination, not automatic full-calendar, notes,
project, or audio synchronization. Paired devices may include Hall-e for Mac.

- **Data collection:** The shared-workspace path transmits data to the
  developer-operated Hall-e coordinator when users explicitly create/join and
  share sessions. The coordinator stores encrypted meeting payloads and
  plaintext coordination metadata listed above. The service is hosted on
  Cloudflare infrastructure; verify Cloudflare's role and any network/security
  log retention for the production account before final disclosures. Prepare
  applicable Data Safety declarations for the exact transmitted data types,
  recipients, and retention, and verify against the final deployment before
  publication. The unpaired calendar, notes, projects, and recordings remain
  local.
- **Data sharing:** Users explicitly share encrypted meeting details with other
  devices in their workspace. The coordinator processes encrypted session
  payloads and lease/device metadata. Separately, a user can explicitly share a
  Markdown note through Android's Sharesheet, or open a meeting URL in another
  app/browser. [Google Play Data safety guidance](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en).
- **Security in transit:** Coordinator requests use HTTPS; meeting details are
  also encrypted on the client before transmission. Device tokens and workspace
  keys are protected at rest with Android Keystore. Audio is not transmitted.
- **Data retention/deletion:** Invitations are single-use and expire after 10
  minutes. Device credentials expire within 90 days. Coordinator workspace data
  expires after seven days without activity; confirm expiry enforcement against
  the deployed service. Leaving revokes that device's future access, but does
  not erase data cached on other paired devices. The owner must revoke other
  devices before leaving. Confirm whether the Console requires a deletion-
  request URL or contact process for this workspace data.

The candidate privacy notice is `website/public/android-privacy.html`, with its
source draft at `docs/store/android/privacy-policy.md`. Both distinguish the
existing 0.1.0 internal-track app from the 0.2.0 candidate, describe optional
encrypted shared sessions, coordinator-visible metadata, and on-device-only
audio. Keep the English and Spanish disclosures aligned if behavior changes.

## Candidate validation status

The Android 0.2.0/code 2 candidate passed 12 Android unit tests, debug lint and
debug assembly. Signed APK/AAB release lint also succeeded. The signed release
build installed on a Pixel and showed code 2. Real-device QA created a local
project and quick meeting, then assigned a meeting to an existing project.
After explicit Save and Record selection and the OS “Only this time” microphone
grant, a 15-second recording stopped as Recorded and played in-app. Audio was
not uploaded. This verifies local recording only. Local and deployed HTTP
simulation checks passed for the coordinator, but pairing and Mac/phone lease
handoff remain unverified: the user could not scan a fresh invitation QR during
this QA session, and a previously expired invitation was rejected as invalid.
The deployed service checks do not substitute for a successful on-device
handoff. The Play draft release 2 finished processing, with one TV-device
availability warning and no mapping file (release minification is disabled).
It is not published. The public production-access gate still requires the
applicable closed test of 12 testers for 14 days; preserve that gate.

## Owner confirmation required

- Select actual target age groups and answer whether the app is directed to
  children. “Productivity for adults” is a product positioning suggestion, not
  evidence of the owner's intended age audience or a legal classification.
- Complete Google's content-rating questionnaire from the released app and
  intended audience. Source review shows a calendar/productivity utility with
  no ads, public posting, or in-app account system; do not infer all rating
  answers from that alone.
- Check that the proposed support URL is reachable and the privacy notice
  matches the final signed release before publication.

## Source evidence

- `android/app/src/main/AndroidManifest.xml` — permissions, exported app
  surface, coordinator network permission, and pairing-link intents.
- `android/app/build.gradle.kts` — application ID, version, API levels, release
  signing inputs, debug-only application ID suffix, and dependencies.
- `android/app/src/main/java/app/halle/companion/CalendarRepository.kt` —
  calendar-provider fields, attendee decline check, meeting-link extraction.
- `android/app/src/main/java/app/halle/companion/LocalStore.kt` — persisted local
  preference keys and notes/projects.
- `android/app/src/main/java/app/halle/companion/MainActivity.kt` — permission
  request timing, note-share fields, and user-directed external link opening.
- `docs/store/android/listing-en-US.md` and
  `docs/store/android/listing-es-419.md` — listing claims and suggested category.
