# Hall-e for Android — Google Play listing draft (English, United States)

This is the calendar companion for Hall-e. The original 0.1.0 build is local-only. Version 0.2.0/code 3, which adds optional recording and shared meetings, is currently available only to the owner’s Google Play internal testers; this listing draft describes that candidate for a future public release. Shared workspaces coordinate selected meeting details with paired Hall-e devices, including Hall-e for Mac.

The full English and Spanish listings and real screenshots `03-shared-sessions.png` and `04-local-recording.png` are saved in Google Play Console for the 0.2.0/code 3 candidate. The app icon and feature graphic are marked AI-generated in Console. The owner explicitly confirmed sending 15 changes. The Publishing overview says: “Your changes are now in review. We may find additional issues when reviewing your app.” Quick checks completed successfully. Closed testing release 1 for code 3 is configured for Chile only with the unchanged owner-only tester list (one user); it is not active or public. The internal code 3 track remains active and is not a public release.

## Store listing

- **App name (27/30):** Hall-e: Meetings & Projects
- **Short description (77/80):** Instant meetings, local phone recording, optional paired-device coordination.
- **Full description (under 4,000 characters):**

  Make room for a calmer, more organized day with Hall-e.

  **See today at a glance**
  Choose which calendars on your phone appear in Hall-e. Browse a day at a time, check meeting details, and open supported meeting links in the app or browser you already use.

  **Keep project context close**
  Group meetings into local projects. Write or update a Markdown note for a meeting, then share it yourself using Android’s share sheet.

  Create an instant meeting with a title, date, and time, then assign it to an existing project or create a new one. In an optional paired workspace, request recording handoff between devices; each device still requires its own explicit recording action and microphone permission.

  **Set meeting reminders**
  Choose a reminder at the meeting start, 1, 5, 10, 15, or 30 minutes beforehand, or set a custom lead time. If enabled, the morning overview appears the first time you open Hall-e from 4:00 a.m. until noon.

  **Your calendar stays on your phone**
  Hall-e reads only the calendars you select. Calendar entries, notes, and reminder settings stay local. If you choose to pair a shared workspace, selected meeting titles, optional project names or meeting links, and scheduled times are encrypted on your phone and sent with coordination metadata to Hall-e's coordinator for paired devices. In this shared-workspace flow, calendar IDs, attendee lists, full calendar records, and audio are not sent to the coordinator. This is not automatic calendar, notes, project, or audio sync. There is no Hall-e account system.

  Optional recording captures audio from this phone's microphone only after you choose to record and grant permission. Android or another audio app may affect microphone capture; it may not capture remote participants or other apps. Hall-e does not upload recordings automatically or to its coordinator. You can explicitly export a recording through Android's share sheet and choose a destination; that app or service may process or retain the file under its own privacy practices. Hall-e does not transcribe conversations or request contacts or location access.

  Android controls calendar permission, notification permission, and exact-alarm access. If a permission is off, reminders may not appear or may arrive later than requested. The morning overview is shown when you open Hall-e from 4:00 a.m. until noon; Android may not launch the app for you before you open it.

- **Support contact:** gabriel.aldea@gmail.com (published public support email; Hall-e does not claim ownership of hall-e.com).
- **Privacy policy URL:** https://hall-e.pages.dev/android-privacy.html (saved in Play Console; Publishing overview says changes are in review and quick checks completed successfully). The existing root `PRIVACY.md` describes the Mac app and is not a substitute for Android disclosures.
- **Category suggestion:** Productivity
- **Tags suggestion:** Calendar, Productivity

## Graphics

- **App icon:** [`hall-e-play-icon-512.png`](hall-e-play-icon-512.png), marked AI-generated in Play Console.
- **Feature graphic:** [`feature-graphic-1024x500.png`](feature-graphic-1024x500.png), marked AI-generated in Play Console. It contains no simulated app screen or fabricated screenshot.
- **Editable source and regeneration instructions:** [`generate-assets.py`](generate-assets.py) (Python 3 and Pillow).
- **Screenshots:** [`03-shared-sessions.png`](screenshots/03-shared-sessions.png) and [`04-local-recording.png`](screenshots/04-local-recording.png) are real QA captures, mechanically cropped/resized with provenance in [`provenance.md`](screenshots/provenance.md). They are saved in the Play listing; they are not AI-generated or labeled as such. Use these instead of stale screenshot 01.
