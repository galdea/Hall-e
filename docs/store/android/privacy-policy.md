# Hall-e for Android privacy notice

Source draft for the public page at `website/public/android-privacy.html`. Keep the two versions aligned before deploying changes.

## Local agenda and invitation-based pairing in earlier builds

The earlier 0.1.0 build uses the local agenda. The 0.2.0 build distributed through internal testing (version code 3) also supports microphone recording and invitation-based pairing. Neither of those builds creates a Hall-e account. The account features below apply only to a build with Private Agenda connected to a configured account service. This notice does not announce a Google Play release.

With your permission, Hall-e reads the calendars you select through Android’s calendar provider. It uses event data on your phone to show your agenda, open supported meeting links, organize meetings into local projects, and schedule reminders. To filter invitations declined by the calendar account, it reads attendee email addresses and response statuses on-device; it does not store attendee lists. Hall-e does not request calendar write access. Events are read from Android when Hall-e builds or refreshes the agenda; Hall-e does not create a separate server-side calendar copy.

Hall-e stores selected calendar IDs, project names, meeting-to-project assignments, Markdown notes, reminder settings, and reminder occurrence IDs in the app’s private local storage. An occurrence ID is derived from the calendar ID, event ID, and occurrence start time; Hall-e uses it to schedule, cancel, and avoid duplicate reminders. Android manages access to calendar events.

If you choose to record, Hall-e records audio from this phone's microphone only after a visible action and microphone permission. A foreground notification remains visible with Stop. Android or another audio app may silence or affect the microphone, and phone recording may not capture remote participants or other apps. Recordings are saved in app-private storage on this phone; Hall-e does not upload them to its coordinator or transcribe speech. From a recording card, you may explicitly choose **Share audio** (or share an interrupted partial file) and select a destination in Android's Sharesheet. Hall-e grants that destination access to the selected file; the receiving app or service may copy or process it under its own practices. Hall-e does not share audio automatically. Hall-e does not request access to contacts or location.

If you choose to create or join a shared workspace, Hall-e sends encrypted meeting details (title and optional project name, supported meeting URL, and scheduled start/end times) to the allowlisted Hall-e coordinator. These details are encrypted on your device before transmission and can be shared with paired devices. A title or time may come from a calendar event you selected, but calendar event IDs, attendee lists, and a calendar copy are not sent. The coordinator also stores opaque workspace, device, session, and segment identifiers; display-only device names; session ciphertext; segment timestamps and status; hashes of invitation and device credentials; and temporary recording-lease metadata. It does not receive audio, transcripts, or your encryption key. Workspace credentials and the encryption key are protected with Android Keystore and stored encrypted on the phone. Invitations are one-use and expire after 10 minutes. Device credentials expire within 90 days; an inactive workspace expires after seven days. Leaving revokes that device's future access but cannot remove meeting metadata cached on other devices.

Hall-e's developer operates the coordinator, which runs on Cloudflare Workers. Cloudflare may process network and request metadata as an infrastructure provider; see [Cloudflare's privacy policy](https://www.cloudflare.com/privacypolicy/). Account-specific platform logs and retention depend on the deployed service configuration.

Supported meeting links open in another app or browser on your phone. The receiving service may handle information under its own privacy practices. If you choose to share a Markdown note, Android opens its system share sheet, and Hall-e sends the note only after you choose a destination. Hall-e does not share notes automatically. The same applies to an audio export: you choose the recording and destination, and the recipient's privacy practices apply after the file is shared.

Hall-e schedules reminders locally through Android. Android controls calendar permission, notification permission, and exact-alarm access. If access is denied, revoked, or restricted, a reminder may not appear or may arrive later than requested. The morning overview is prepared when you open Hall-e during its morning window; the app does not promise to launch itself in the background.

Local preferences, notes, projects, assignments, recordings, and calendar selections remain in the app’s private storage until you clear Hall-e’s app data or uninstall the app. Recordings remain on the recording phone unless you explicitly export them; they are not automatically uploaded or shared across workspaces. Leaving a shared workspace revokes that device's access; it does not delete workspace data still available to other devices. Separately remove any note or audio copies kept by receiving apps or services.

## Optional Private Agenda account

### Optional private account

You can use the local agenda without signing in. To use Private Agenda, choose an email code or sign in with Google in your browser. The email delivery service receives your address and sign-in code. With Google, Hall-e receives your verified email address and Google account identifier. The service keeps an internal account ID, linked sign-in identities and session records. You explicitly confirm when linking another method. Google sign-in grants no access to Google Calendar.

### What appears on your other devices?

Creating or editing a private meeting sends its ID, title, start and end times and, if you assign a private project, its ID and name to the account service. Other devices signed in to the same account can read these details and shared transcripts. A selected local meeting can be copied after confirmation. The copy uses the selected title and times and leaves attendee lists, notes, links, local projects and source calendar permissions on the device. Edits to the private meeting do not change the source calendar.

### Audio and transcription

Opening a meeting does not start recording. Ask participants for consent before recording, then start the microphone on the phone. To send an account recording for transcription, approve the named provider, Deepgram or Speechmatics. Hall-e queues the file locally for retry when internet access returns. The account service stores audio in private Cloudflare R2 storage and uses D1 for account and meeting records, processing status, audio digests and transcript text. The selected provider receives the audio to produce the transcript. The account service can process this content. The encrypted pairing coordinator described above never receives it.

### Deleting a shared meeting and signing out

Use “Delete from account…” in Private Agenda to remove a meeting from the shared calendar. Once the service accepts deletion, it hides the meeting, removes imported text and schedules cleanup of its stored audio and transcription. Offline devices receive the change when they sync. Incomplete uploads expire after seven days of inactivity. Signing out hides account data on this device and revokes its session when online. Other sessions stay active. Clearing app data, uninstalling or revoking microphone or calendar permission does not delete information already sent. Local originals, exports, provider copies and backups have separate retention. Deleting a meeting does not delete the account. This candidate has no account-deletion control.

## Agenda privada opcional

### ¿Qué versión tienes?

La versión anterior 0.1.0 usa la agenda local. La versión 0.2.0 distribuida en las pruebas internas (código de versión 3) también permite grabar con el micrófono y emparejar dispositivos por invitación. Ninguna de esas versiones crea una cuenta de Hall-e. Las funciones de cuenta que se describen aquí se aplican solo a una versión que incluye Agenda privada y se conecta a un servicio de cuentas configurado. Este aviso no anuncia un lanzamiento en Google Play.

### Cuenta privada opcional

Puedes usar la agenda local sin iniciar sesión. Para usar Agenda privada, solicita un código por correo o inicia sesión con Google desde el navegador. El servicio de entrega de correo recibe tu dirección y el código de acceso. Si eliges Google, Hall-e recibe tu correo verificado y tu identificador de cuenta de Google. El servicio guarda un identificador interno de cuenta, los métodos de acceso vinculados y los registros de sesión. Vincular otro método requiere tu confirmación. Iniciar sesión con Google no concede acceso a Google Calendar.

### ¿Qué aparece en tus otros dispositivos?

Cuando creas o editas una reunión privada, se envían al servicio de cuentas su identificador, título, inicio y fin y, si le asignas un proyecto privado, el identificador y nombre del proyecto. Los dispositivos conectados a la misma cuenta pueden leer estos datos y las transcripciones compartidas. Puedes copiar una reunión local tras seleccionarla y confirmarlo. Se copian el título y los horarios elegidos. La lista de asistentes, las notas, los enlaces, los proyectos locales y los permisos del calendario de origen permanecen en el dispositivo. Editar la reunión privada no modifica el calendario de origen.

### Audio y transcripción

Abrir una reunión no inicia la grabación. Pide el consentimiento de los participantes antes de empezar a grabar con el micrófono del teléfono. Para transcribir una grabación de la cuenta, confirma el proveedor indicado, Deepgram o Speechmatics. Hall-e guarda el archivo en una cola local para reintentar el envío cuando vuelva la conexión. El servicio de cuentas guarda el audio en almacenamiento privado de Cloudflare R2. En D1 guarda los registros de cuenta y reunión, el estado del procesamiento, las huellas digitales del audio y la transcripción. El proveedor elegido recibe el audio para producir el texto. El servicio de cuentas puede procesar ese contenido. El coordinador de emparejamiento cifrado descrito arriba nunca lo recibe.

### Eliminar una reunión compartida y cerrar sesión

Usa «Delete from account…» en Agenda privada para eliminar la reunión del calendario compartido. Cuando el servicio acepta el borrado, oculta la reunión, elimina el texto importado y programa la limpieza del audio y la transcripción almacenados. Los dispositivos sin conexión reciben el cambio al sincronizar. Las cargas incompletas caducan tras siete días de inactividad. Cerrar sesión oculta los datos de la cuenta en este dispositivo y revoca su sesión cuando hay conexión. Las demás sesiones siguen activas. Borrar los datos de la app, desinstalarla o revocar el permiso de micrófono o calendario no elimina información ya enviada. Los originales locales, las exportaciones, las copias del proveedor y las copias de seguridad tienen una conservación independiente. Eliminar una reunión no elimina la cuenta. Esta versión candidata carece de un control para eliminar la cuenta.

For support, use the [Hall-e issue form](https://github.com/galdea/Hall-e/issues/new/choose).
