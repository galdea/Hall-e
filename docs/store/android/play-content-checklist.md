# Google Play Console: App content and Data Safety

Source-backed preparation for the Android release. This records product behavior
and the owner's selected Console declarations. It is not a legal attestation.

## App details

- **Release application ID:** `app.halle.companion` (`android/app/build.gradle.kts`,
  `defaultConfig.applicationId`). The debug build uses `app.halle.companion.preview`
  and must not be uploaded.
- **Existing internal-track release:** `versionName` `0.1.0`, `versionCode` `1`.
  The current source candidate is `0.2.0`, `versionCode` `3`, per
  `android/app/build.gradle.kts`. The updated recording and shared-workspace
  disclosures apply to that candidate. The signed code 2 AAB was uploaded and
  saved as internal-track draft release 2; it is historical. Signed code 3
  APK/AAB and lint passed with 14 Android tests, and the APK was installed on
  the Pixel with version code 3 confirmed. The paired workspace remained
  preserved and refresh no longer showed a false handoff state. Google Play's
  Internal testing track is Active for code 3 since Oct 20 at 2:21 AM, available
  to the unchanged owner-only tester list. This is an internal release, not a
  public production release.
- **Minimum Android:** API 31 (Android 12); **target/compile:** API 36.
- **Suggested category:** Productivity, matching the listing draft.
- **Ads:** No ads are implemented and there is no ads SDK in the app dependencies.
  Answer **No** if the release candidate remains unchanged.
- **Account/app access:** No sign-in, Hall-e account, external account login,
  username, password, purchase, or trial is needed. For Console's access
  instructions, answer **Yes** because the optional paired-workspace feature
  requires a second device. Provide these setup steps, without credentials:
  install Hall-e on two devices; on the first, create a workspace (no account
  registration), create an invitation, and open it on the second device; accept
  the invitation explicitly; create a quick meeting and explicitly choose
  Record, then stop it. The local calendar and meeting features remain usable
  without pairing.
- **Support and privacy:** The published public support email is
  `gabriel.aldea@gmail.com`; do not use or claim `hall-e.com`. The Play privacy
  policy URL `https://hall-e.pages.dev/android-privacy.html` is saved. The
  Publishing overview says: “Your changes are now in review. We may find
  additional issues when reviewing your app.” The owner confirmed sending 15
  changes, and Play's quick checks completed successfully.
- **Target audience:** Owner-selected ages 13–15, 16–17, and 18+; do not include
  children under 13.
- **Content rating:** IARC questionnaire completed and assigned Everyone,
  PEGI 3, and 3+. The “Users Interact” descriptor reflects private device
  pairing. Workspace access is invitation-only and revocable; there is no
  public user-generated content.

## Data Safety: saved declaration, changes in review

The owner authorized and saved the Data Safety form. It declares **Device or
other IDs** (collected, optional, non-ephemeral; App functionality and Fraud
prevention, security, and compliance purposes) and **App activity → App
interactions** (collected, optional, non-ephemeral; App functionality purpose).
It records **no reportable sharing**, applying the service-provider and
user-directed transfer exceptions to the coordinator and explicit shares.
Encryption in transit is declared **Yes**. There is no account system or
external account login, and no data-deletion request route is provided. The form
is included in the submitted Play changes, now in review after quick checks
completed successfully. Update the declaration if a data flow or provider
changes.

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
  developer-operated coordinator when users create or join a workspace. The
  coordinator receives encrypted meeting payloads and plaintext coordination
  metadata. The saved declaration covers Device or other IDs and App
  interactions; local-only data and end-to-end encrypted meeting details are
  not included as collected. The unpaired calendar, notes, projects, and
  recordings remain local.
- **Data sharing:** The saved form records no reportable sharing under the
  owner-approved service-provider and user-directed transfer exceptions. Users
  explicitly share encrypted meeting details with other devices in their
  workspace; the coordinator processes encrypted session payloads and
  lease/device metadata. A user can also explicitly share a
  Markdown note or export a completed recording (or an interrupted partial
  recording file) through Android's Sharesheet after choosing a destination.
  The chosen receiving app/service may process or retain the file under its own
  practices. These are user-directed shares, not automatic uploads or
  coordinator audio transfers. Do not interpret “not sent to the coordinator”
  as “never shared.” [Google Play Data safety guidance](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en).
- **Security in transit:** Coordinator requests use HTTPS; meeting details are
  also encrypted on the client before transmission. Device tokens and workspace
  keys are protected at rest with Android Keystore. Hall-e does not upload
  recordings automatically or send them to the coordinator. If a user exports a
  recording, Hall-e grants the selected destination access through Android's
  Sharesheet; the selected app/service controls further handling.
- **Data retention/deletion:** Invitations are single-use and expire after 10
  minutes. Device credentials expire within 90 days. Coordinator workspace data
  expires after seven days without activity. Active workspaces may persist
  longer; device-token expiry does not delete workspace data. Leaving revokes
  that device's future access, but does not erase data cached on other paired
  devices. The owner must revoke other devices before leaving. No route is
  provided for users to request deletion of coordinator data; the saved form
  does not claim a deletion-request mechanism.

The candidate privacy notice is `website/public/android-privacy.html`, with its
source draft at `docs/store/android/privacy-policy.md`. Both distinguish the
existing 0.1.0 internal-track app from the 0.2.0 candidate, describe optional
encrypted shared sessions and coordinator-visible metadata, and distinguish
local recording from user-directed audio export. Keep the English and Spanish
disclosures aligned if behavior changes.

## Candidate validation status

The historical Android 0.2.0/code 2 candidate passed 12 Android unit tests,
debug lint and debug assembly. Its signed APK/AAB release lint succeeded and
the APK installed on a Pixel as code 2. Real-device QA created a local
project and quick meeting, then assigned a meeting to an existing project.
After explicit Save and Record selection and the OS “Only this time” microphone
grant, a 15-second recording stopped as Recorded and played in-app. Audio was
not uploaded. Physical paired-device recording QA with the Store QA Mac passed:
the Pixel's interrupted 41-second segment was preserved when Mac claimed
recording, Mac stopped on the Pixel's handoff request, and an explicit Pixel
restart produced a 13-second recorded segment. No audio was exported in this
QA. A previously expired invitation was rejected as invalid. Physical handoff
QA used code 2's unchanged recording logic. For code 3, **14 Android tests
passed**, signed APK/AAB and lint passed (`android-code3-final.log`), and the
APK installed on the Pixel with version code 3 confirmed. Its paired workspace
remained preserved and refresh no longer showed a false handoff state. The
null-handoff/poll-drop fix was checked by tests and UI refresh. APK SHA-256:
`d8bfbbcfd48e80dbbba033a57d6159cc88f10d08f32adfe85cb781f646fcbc7a`; AAB
SHA-256: `4109e0ae8d2c4645217f248c4a38564b1a69512b34b5dfa4f9fb0ce3c7ca7c49`.
Google Play's Internal testing track is Active for code 3 since Oct 20 at 2:21
AM, available to the unchanged owner-only tester list. Closed testing release 1
for code 3 is configured for Chile only, with the same one-owner tester list;
it is not active and is not public. The public production-access gate still
requires 12 testers for 14 days after a qualifying closed test begins.

## Owner-confirmed Console settings

- Target audience: ages **13–15, 16–17, and 18+**; under 13 excluded.
- IARC: **Everyone / PEGI 3 / 3+**, with “Users Interact” for private,
  invitation-only pairing; no public user-generated content.
- Support email `gabriel.aldea@gmail.com` is published. The privacy policy URL
  is saved in Play Console. The Publishing overview says: “Your changes are now
  in review. We may find additional issues when reviewing your app.” Quick
  checks completed successfully.
- English and Spanish listing text and screenshots 03 and 04 are saved in Play
  Console for code 3. The app icon and feature graphic are marked AI-generated;
  the real QA screenshots are not AI-generated. The owner explicitly confirmed
  sending 15 changes, and the Publishing overview says: “Your changes are now
  in review. We may find additional issues when reviewing your app.” Quick
  checks completed successfully. Closed testing release 1 is configured for Chile only with
  the unchanged owner-only tester list (one user); it is not active or public.
  Initial Play setup is complete, including IARC, Data Safety, English and
  Spanish (es-419) listing entries, and microphone foreground-service and
  Advertising ID = No declarations. Do not treat the closed test as active or
  the listing as publicly available until Play confirms those states.

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
- `docs/store/android/screenshots/provenance.md` — provenance for screenshot
  candidates 03 and 04, selected in place of stale screenshot 01.
