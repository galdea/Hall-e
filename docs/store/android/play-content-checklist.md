# Google Play Console: App content and Data Safety

Source-backed preparation for the Android release. This records product behavior
and recommended answers; owner-only declarations are marked for confirmation.
Do not treat this as a legal attestation.

## App details

- **Release application ID:** `app.halle.companion` (`android/app/build.gradle.kts`,
  `defaultConfig.applicationId`). The debug build uses `app.halle.companion.preview`
  and must not be uploaded.
- **Current release version:** `versionName` `0.1.0`, `versionCode` `1` in the same
  Gradle file. Confirm these are the intended first Play release values before
  creating the bundle; later uploads require a higher version code.
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

The manifest declares `READ_CALENDAR`, `POST_NOTIFICATIONS`,
`SCHEDULE_EXACT_ALARM`, and `RECEIVE_BOOT_COMPLETED`. It does **not** declare
`INTERNET`, calendar write, microphone, contacts, location, camera, or storage
permissions. Runtime calendar access is read-only through Android's calendar
provider. The only production dependencies are AndroidX Core KTX; JUnit is
test-only. There is no analytics, advertising, or crash-reporting SDK visible in
the Android dependency list.

Calendar data used on-device includes event and calendar IDs, event start/end,
title, location, all-day status, event status, description/custom URI (to find
supported meeting links), and attendee email/status (to exclude a declined
invitation matching the calendar account). `LocalStore` persists selected
calendar IDs, projects and meeting assignments, Markdown notes, reminder
preferences, morning-summary date, and reminder/delivery occurrence identifiers
in app-private SharedPreferences. It does not copy full event records to a
separate database or send them to a Hall-e server.

- **Data collection:** **No.** Google defines collection as transmitting data
  from the app off the device. There is no `INTERNET` permission or network SDK;
  calendar processing and preferences are local.
- **Data sharing:** **No.** Hall-e does not automatically transfer data to a
  developer server or SDK. A user can explicitly share a Markdown note via Android's
  Sharesheet; that export contains the meeting title, date, calendar name,
  optional project, and note text. Tapping a supported meeting link launches
  another app/browser with that URL. Google says transfers based on a specific
  user-initiated action, where the user reasonably expects the data to be
  shared, do not need to be declared as sharing. The Sharesheet and link-open
  actions meet that description. Keep the policy's explanation of these
  explicit handoffs. [Google Play Data safety guidance](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en).
- **Security in transit:** Hall-e itself makes no network request. No
  developer-controlled transport or in-transit encryption claim applies to
  external apps chosen by the user.
- **Data deletion:** No remote account or developer-held data store exists.
  Local data is removed when the user clears Hall-e's app storage or uninstalls
  it; separately shared copies must be deleted with the receiving app/service.
  If the Console requests a deletion-request URL, confirm whether it is
  inapplicable for this local-only release rather than inventing a request
  endpoint.

The candidate privacy notice is `website/public/android-privacy.html`, with its
source draft at `docs/store/android/privacy-policy.md`. Both now describe the
on-device attendee email/status lookup, that attendee lists are not stored, and
the locally persisted reminder occurrence IDs. Keep the English and Spanish
disclosures aligned if behavior changes.

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
  surface, and no network permission.
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
