# Optional Google Calendar setup

Recording and transcription work without Google Calendar. The current calendar integration uses your own Google Cloud Desktop OAuth client.

1. Create a project in [Google Cloud Console](https://console.cloud.google.com/).
2. Enable the **Google Calendar API**.
3. Configure the OAuth consent screen and add your Google accounts as test users when using testing mode. Testing-mode refresh tokens may expire, requiring reconnection.
4. Create an **OAuth client ID → Desktop app** and download its JSON.
5. In Hall-e, open **Settings → Accounts → Import client JSON**, then add your Google account. Repeat sign-in for additional accounts.
6. Choose the calendars you want and configure **Settings → Reminders**.

Hall-e requests read-only calendar access. Never commit your downloaded client configuration or refresh tokens. A simpler shared sign-in flow is a future improvement; it requires a maintainer-managed and appropriately verified Google OAuth application.
