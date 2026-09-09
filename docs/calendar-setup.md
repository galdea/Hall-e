# Connect calendars and meeting invitations

First-run setup includes **Connect your meeting accounts**. You can also open **Settings → Accounts** later.

## Recommended: use accounts on your Mac

1. Click **Open Internet Accounts** in Hall-e.
2. Add **Google** for Gmail or Google Workspace, or **Microsoft Exchange** for a supported Outlook/Microsoft 365 work or school account. Sign in with the provider and enable **Calendars**. Existing accounts only need Calendars enabled.
3. Open Apple Calendar and confirm your meetings appear. Hall-e can import calendars available there, including iCloud and supported other accounts. Signing into the standalone Outlook app does not automatically add its calendars to macOS. Personal Outlook.com or organization-restricted accounts may need a calendar subscription or another setup supported by Apple Calendar; Hall-e does not provide a direct Microsoft Graph connection.
4. Return to Hall-e and click **Allow Calendar access**. macOS requests Full Access because EventKit has no read-only permission; Hall-e only reads events and never changes them.
5. Select the calendars you want. New calendars start **unselected**. Hall-e imports meeting details, attendees, invitation responses, and recognized meeting links, then shows them in the workspace for project assignment and reminders.

**Teams meetings:** connect the Microsoft calendar that contains the invitation. Hall-e recognizes Teams join links in the event URL, location, or notes. This does not connect Teams chat or read your mailbox.

macOS handles account passwords and sign-in. No Google Cloud or Microsoft Entra application registration is needed for this route. Your employer may restrict third-party calendar access. Hall-e reads macOS's synchronized calendar cache, so first allow Apple Calendar to finish syncing. Calendar changes trigger a refresh; the existing periodic refresh remains in place.

Choose each calendar through one connection if you also use the advanced Google integration. Provider identifiers can differ between connections, so duplicate detection cannot always merge both copies.

**Disconnect** removes Hall-e's imported Mac-calendar cache and updates reminders; it leaves your macOS accounts and original events intact. Revoke Calendar permission in System Settings → Privacy & Security → Calendars if desired. Project assignments, generated notes, and recordings are separate local records and are retained.

See [Apple's account setup guide](https://support.apple.com/guide/mac-help/add-an-internet-account-mh43559/mac).

## Advanced: direct Google Calendar connection

This existing option remains available under **Settings → Accounts → Advanced: direct Google Calendar connection**. It is useful when you prefer a direct read-only Google API connection instead of macOS Calendar access.

1. Create a project in [Google Cloud Console](https://console.cloud.google.com/) and enable the **Google Calendar API**.
2. Configure the OAuth consent screen and add your accounts as test users when using testing mode. Testing-mode refresh tokens may expire.
3. Create an **OAuth client ID → Desktop app** and download its JSON.
4. Import the client JSON in Hall-e, add your Google account, then select calendars in **Settings → Calendar**.

Never commit client configuration or refresh tokens. Recording and transcription also work without a calendar account.
