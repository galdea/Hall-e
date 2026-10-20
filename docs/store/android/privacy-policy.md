# Hall-e for Android privacy notice

Source draft for the public page at `website/public/android-privacy.html`. Keep the two versions aligned before deploying changes.

Hall-e for Android is a local calendar companion. It does not request network access, create an account, synchronize with Hall-e for Mac, or send analytics to the developer.

With your permission, Hall-e reads the calendars you select through Android’s calendar provider. It uses event data on your phone to show your agenda, open supported meeting links, organize meetings into local projects, and schedule reminders. To filter invitations declined by the calendar account, it reads attendee email addresses and response statuses on-device; it does not store attendee lists. Hall-e does not request calendar write access. Events are read from Android when Hall-e builds or refreshes the agenda; Hall-e does not create a separate server-side calendar copy.

Hall-e stores selected calendar IDs, project names, meeting-to-project assignments, Markdown notes, reminder settings, and reminder occurrence IDs in the app’s private local storage. An occurrence ID is derived from the calendar ID, event ID, and occurrence start time; Hall-e uses it to schedule, cancel, and avoid duplicate reminders. Android manages access to calendar events.

Hall-e for Android does not record meetings or audio, transcribe speech, or use a microphone. It does not request access to contacts or location.

Supported meeting links open in another app or browser on your phone. The receiving service may handle information under its own privacy practices. If you choose to share a Markdown note, Android opens its system share sheet, and Hall-e sends the note only after you choose a destination. Hall-e does not share notes automatically.

Hall-e schedules reminders locally through Android. Android controls calendar permission, notification permission, and exact-alarm access. If access is denied, revoked, or restricted, a reminder may not appear or may arrive later than requested. The morning overview is prepared when you open Hall-e during its morning window; the app does not promise to launch itself in the background.

Local preferences, notes, projects, assignments, and calendar selections remain in the app’s private storage until you clear Hall-e’s app data or uninstall the app. If you shared a note, separately remove any copy kept by the receiving app or service.

For support, use the [Hall-e issue form](https://github.com/galdea/Hall-e/issues/new/choose).
