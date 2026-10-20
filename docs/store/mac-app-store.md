# Mac App Store preparation

This is a separate distribution path from `scripts/release.sh`. Direct releases
remain ad-hoc or Developer ID signed and are not changed by
`MacAppStore.entitlements`. The App Store candidate is an Apple-signed sandboxed
build installed through `/Applications`; it is not uploaded or submitted by the
local packaging script.

## Current readiness

**Do not package or submit this as a release-ready Mac App Store build yet.**
The Store-specific source flag compiles successfully, selected notes folders
use app-scoped bookmarks, and the OAuth callback listener is bound to
`127.0.0.1`. Clean signed, installed sandbox QA has not been completed. No
valid signing identities or matching distribution profile are available, so
signing and installation remain unverified. Set the packaging script's
`STORE_SANDBOX_READY=1` gate only after code review and clean installed-package
QA are complete.

The source audit found these distribution-specific behaviors and remaining
validation requirements before the gate may be set:

| Area | Current behavior | App Store work required |
| --- | --- | --- |
| Persistent app data | `AppPaths.appSupport` uses `FileManager`'s user Application Support directory. In the Store build, the sandbox directs this app-support data into Hall-e's container. | Verify the signed installed build reads and writes its app-support state in the container. Ensure the privacy policy accurately describes the Store edition's container-scoped data. |
| Chosen notes folders | App Store builds store and resolve a security-scoped bookmark for the selected folder, reuse one active scope while the app is running, stop it when replacing the selection or exiting, and ask the user to reselect when a legacy or revoked bookmark cannot be resolved. Direct builds keep their existing path fallback. | Installed-package QA still needs an external volume, a moved folder after restart, a legacy direct-edition config, and revoked access. |
| Calendar | EventKit reads selected macOS calendars; Google Calendar uses OAuth with an HTTP callback listener bound to `127.0.0.1`. | Request the Calendar permission as it does today. Verify Calendar access and the loopback callback in the signed installed build with the Calendar and network entitlements. |
| Recording audio | Microphone capture remains available. App Store builds disable process-tap recording and desktop/browser call detection pending installed sandbox QA; the manual recorder presents microphone-only behavior. | Test microphone capture in the installed package. Do not advertise app-audio capture for the Store edition without successful clean-system QA and review. |
| OpenClaw reports | Store compilation disables local executable discovery and `Process` launching, the report pipeline fails closed, and Settings explains the distribution limit. | Verify the feature stays unavailable in an installed Store build. Direct downloads retain the integration. |
| Chrome integration | The Store edition does not bundle the Chrome native-messaging helper. Store builds disable the settings controls, native-message queue ingress, extension preparation, and manifest installation. | Verify Chrome integration remains unavailable in the signed installed Store build. |
| Codex import | Store compilation removes the `~/.codex` path and importer body; coordinator methods reject refresh/link actions, and the UI offers explicit ChatGPT JSON/WhatsApp exports instead. ChatGPT ZIP extraction is disabled because the direct path uses an external process. | Verify no Codex-home access or external archive process occurs in the installed Store build. Direct downloads retain Codex and ZIP imports. |
| Existing direct installs | Direct releases continue using their current Application Support and Keychain locations. A sandboxed Store build uses its container's Application Support and Keychain domains. | Verify this behavior with a signed Store installation. |

Apple requires App Sandbox for Mac App Store distribution, restricts access to
user-selected files to the panel/bookmark grant, and prohibits several
cross-application/system activities in sandboxed apps. Store-specific feature
guards keep unsupported optional integrations unavailable in that edition.

## Entitlements

`BundleResources/MacAppStore.entitlements` is a minimal candidate for the
features identified in the code audit:

- App Sandbox.
- Outgoing network for OAuth token exchange, Google Calendar, and opted-in
  transcription providers.
- Calendar read/write capability because EventKit's macOS sandbox entitlement
  is named for full calendar access, although Hall-e's macOS calendar adapter
  performs no event writes.
- Audio input for microphone recording and user-authorized Core Audio input.
- User-selected read/write and app-scoped bookmark access for an explicitly
  chosen notes folder.
- Incoming network supports the ephemeral OAuth callback listener, which is
  bound to `127.0.0.1`. Verify callback behavior in the signed installed build.

No file-all, Downloads, Apple Events, Accessibility, application groups,
privileged file operations, or temporary exception entitlement is included.
The Store edition does not bundle the Chrome native-messaging helper.

## Local package and validation

Prerequisites are Xcode command line tools, a valid Mac App Store application
distribution identity, a matching Mac App Store installer identity, and an
explicit provisioning profile for bundle ID `cl.gabriel.hall-e`. No identity
or profile is generated by the script. The script checks the certificate names,
valid private-key-backed identities, matching Team IDs, the exact profile App
ID and Team ID, profile expiry, and that the selected application certificate
is authorized by the profile before building. It adds the profile's application
identifier and team identifier to the candidate entitlements. The Store-specific
source flag compile has passed. Clean signed, installed sandbox QA has not been
done because no valid code-signing identities or matching distribution profile
are available.

Only after source sandbox adaptation and clean-install QA are complete:

```sh
STORE_SANDBOX_READY=1 \
APPSTORE_APP_IDENTITY='3rd Party Mac Developer Application: Name (TEAMID)' \
APPSTORE_INSTALLER_IDENTITY='3rd Party Mac Developer Installer: Name (TEAMID)' \
APPSTORE_PROFILE='/secure/path/Hall-e-App-Store.provisionprofile' \
VERSION=0.4.0 ./scripts/package-mac-app-store.sh
```

The command creates a signed `.pkg` in `dist/`, validates its signatures and
payload location, and writes a SHA-256 checksum. It **does not upload**. Inspect
the exact package and upload it separately through Apple's Transporter or
App Store Connect. Before upload, use a clean macOS user account to install the
package, verify Activity Monitor reports Hall-e as sandboxed, and exercise every
advertised feature. Check container-scoped privacy data, calendar, microphone,
chosen-folder, notification, recording, playback, and deletion behavior.

## Store listing material

The draft localizations are in [`listing-en-US.md`](listing-en-US.md) and
[`listing-es-CL.md`](listing-es-CL.md). The live App Store name is not reserved;
check its availability in App Store Connect. The selected support link is the
repo's issue form and the privacy link is the existing policy. Before review,
make sure the issue form remains an appropriate customer-support path and
update the policy to explain the App Store container and the separation from
direct-release data accurately.

Screenshots are intentionally not fabricated. Capture the actual signed,
installed App Store build after the UI and sandbox audit is complete. Do not
reuse preview images as product screenshots.

## Primary Apple references

- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)
- [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [App Store Connect listing field limits](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
