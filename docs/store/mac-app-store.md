# Mac App Store preparation

Current source candidate: Hall-e **0.5.0**, commit `f5dde2f`. Build
**2026102010** includes the asynchronous Keychain fixes and retirement of the
OpenClaw integration. The final Store QA app was installed at
`/Applications/Hall-e Store QA.app`, launched, restored its Keychain access to
the live workspace, and passed bidirectional paired-Pixel recording-handoff QA.
The distribution-signed package was signature- and payload-validated, but has
not been uploaded. See [candidate validation](../validation/2026-10-20-hall-e-0.5.0.md).
App Store Connect has saved English and Mexican Spanish listing copy, review
notes, and contact details. App Privacy is published with six data types,
purpose App Functionality, linked to user/device set to Yes, and tracking set to
No (UI confirmation: “Published ... Gabriel”). No build or screenshots have
been uploaded.

This is a separate distribution path from `scripts/release.sh`. Direct releases
remain ad-hoc or Developer ID signed and are not changed by
`MacAppStore.entitlements`. The App Store candidate is an Apple-signed sandboxed
build installed through `/Applications`; it is not uploaded or submitted by the
local packaging script.

## Current readiness

Historical core signed sandbox QA passed for build 2004: it launched from
`/Applications`, resolved the app container, received Calendar permission and
enumerated calendars, completed a six-second microphone recording with
playback, failed closed on a legacy vault configuration, and reopened a moved
vault folder after quit/relaunch with access still writable. A headless smoke
using the actual loopback server and verbatim `ResumeGuard` also received
`code=qa&state=qa` on `127.0.0.1` and returned HTTP 200; its log is
`/private/tmp/hall-e-build-20261020/sandbox-loopback-smoke.log`. The Google
browser/account OAuth flow itself has not been run. External-volume and revoked
folder-permission cases remain untested. Signed build 2005's notification
feedback check confirmed the UI reports “Delivered to Notification Center.”

The earlier core sandbox and notification checks above are historical evidence
from builds 2004–2005. Build 2010 now has installed Store QA: Hall-e launched,
restored Keychain access to the live workspace, and was confirmed paired with
the Pixel. Bidirectional handoff passed: the Pixel's 41-second interrupted
segment remained preserved when Mac claimed recording; Mac stopped when the
Pixel requested handoff; after an explicit Pixel start, its 13-second segment
was recorded. Mac then captured a six-second segment; its first playback showed
“No Speech Detected” for local Speech recognition, and a later Mac segment
completed on-device speech processing. No audio was exported. QA began with AI
off and Apple Speech selected; Speechmatics and AI were restored afterward with
the user's confirmation. No cloud QA upload was performed.

The direct build verified that the retired setting is absent and preserved
Speechmatics selection. Final Store QA build 2010 passed installed startup,
Keychain, live-workspace and paired-device checks. The distribution-signed
0.5.0 package was validated and has SHA-256
`fa76bd23706c5aed48f064a2735f7e59c8a761d947cc156d264d6b9ff9585c5f`; it has
not been uploaded. English and Mexican Spanish listing copy, review notes and
contacts are saved. App Privacy is published for six data types, with purpose
App Functionality, linked to user/device Yes, and tracking No. No screenshots
or build have been uploaded. The repository has no separate hosted
workflow for Mac App Store packaging or validation. The existing macOS GitHub
workflow is for direct-download packages and runs only on a `vX.Y.Z` tag or an
explicit manual dispatch; no hosted run has been made for this candidate.
Installation of Apple's Transporter app is currently blocked at an Apple
account authentication sheet that offers only account selection and Cancel,
with no authentication controls. The user cannot complete installation now;
no upload was attempted. This is an Apple account UI block, not an
automatic-review rejection. The validated package remains local.
`apple-0.5-draft.png` is local proof of the earlier listing draft, not an
uploaded screenshot.

The source audit found these distribution-specific behaviors and remaining
validation requirements before the gate may be set:

| Area | Current behavior | App Store work required |
| --- | --- | --- |
| Persistent app data | `AppPaths.appSupport` resolves within Hall-e's Store container. Preferences carried over for the same bundle ID. Keychain access follows macOS signing identity and access-group rules; do not describe it as a blanket separate Keychain domain. | Build 2004 confirmed a separate container from direct-download app data. Continue checking data deletion and document actual Keychain visibility accurately. |
| Chosen notes folders | App Store builds store and resolve a security-scoped bookmark for the selected folder, reuse one active scope while the app is running, stop it when replacing the selection or exiting, and ask the user to reselect when a legacy or revoked bookmark cannot be resolved. Direct builds keep their existing path fallback. | Build 2004 confirmed a moved folder still resolves after quit/relaunch and remains writable; legacy direct-edition configuration fails closed. External-volume access and revoked permission still need QA. |
| Calendar | EventKit reads selected macOS calendars; Google Calendar uses OAuth with an HTTP callback listener bound to `127.0.0.1`. | Build 2004 Calendar permission and enumeration passed. The actual loopback server smoke passed callback code/state and HTTP 200 with the Store entitlements. Full Google browser/account OAuth flow remains untested. |
| Recording audio | Microphone capture remains available. App Store builds disable process-tap recording and desktop/browser call detection; capture is microphone-only. | Build 2004 six-second microphone recording, playback, and moving the test recording to Trash passed. Do not advertise app-audio capture for the Store edition. |
| OpenClaw/Gemini reports | Retired from all Hall-e editions on 2026-10-20 because the integration was unavailable and unreliable. Current releases must not enqueue/retry report jobs or expose OpenClaw activation settings. Previously created report artifacts and historical schemas are preserved; generic configured AI providers and their separate consent remain independent. | Verify the retired pipeline cannot be invoked in the installed Store build, while legacy report artifacts remain readable and generic AI-provider controls continue to behave separately. |
| Chrome integration | The Store edition does not bundle the Chrome native-messaging helper. Store builds disable the settings controls, native-message queue ingress, extension preparation, and manifest installation. | Verify Chrome integration remains unavailable in the signed installed Store build. |
| Codex import | Store compilation removes the `~/.codex` path and importer body; coordinator methods reject refresh/link actions, and the UI offers explicit ChatGPT JSON/WhatsApp exports instead. ChatGPT ZIP extraction is disabled because the direct path uses an external process. | Verify no Codex-home access or external archive process occurs in the installed Store build. Direct downloads retain Codex and ZIP imports. |
| Existing direct installs | Direct releases keep their existing app data location. Store app support is container-scoped; same-bundle-ID preferences carried over, and Keychain item access follows macOS signing identity/access-group rules. | Build 2004 verified the separate app container and preference carryover. Keychain visibility must be described according to the actual signing identity and access groups. |

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
  bound to `127.0.0.1`. The signed headless loopback smoke passed; the full
  Google browser/account flow remains untested.

No file-all, Downloads, Apple Events, Accessibility, application groups,
privileged file operations, or temporary exception entitlement is included.
The Store edition does not bundle the Chrome native-messaging helper.

## Local package and validation

Prerequisites are Xcode command line tools, a valid Mac App Store application
distribution identity, a matching Mac App Store installer identity, and an
explicit provisioning profile for bundle ID `cl.gabriel.hall-e`. No identity
or profile is generated by the script. The configured development and App Store
distribution certificates and profiles for Team ID `X6TR876MKF` have been
validated (development profile `K5C6RLNJN7`, distribution profile
`VCWUN27GLJ`). The script checks the certificate names,
valid private-key-backed identities, matching Team IDs, the exact profile App
ID and Team ID, profile expiry, and that the selected application certificate
is authorized by the profile before building. It adds the profile's application
identifier and team identifier to the candidate entitlements. The Store-specific
source flag compile has passed. Signed builds 2004 and 2005 passed the core
installed sandbox checks described above, including notification feedback.
Keep the packaging gate closed until code review and the documented QA results
are signed off.

Apple documents that modern Mac App Store distribution-signed builds may not
launch directly before App Review, so the script's local QA mode uses an Apple
Development identity and a matching macOS development profile instead. This
mode signs the same Store-configured build, validates the profile, app ID,
team, certificate, entitlements, and signature, then writes a development-
signed app under `dist/qa/`. It bypasses only the release-readiness gate; it
does not make an App Store distribution package.

Create the local QA app on a registered test Mac:

```sh
STORE_PACKAGE_MODE=qa \
STORE_QA_APP_IDENTITY='Apple Development: Name (TEAMID)' \
STORE_QA_PROFILE='/secure/path/Hall-e-Mac-Development.provisionprofile' \
VERSION=0.5.0 BUILD_NUM=2026102009 ./scripts/package-mac-app-store.sh
```

Builds 2004 and 2005 cover launch, sandbox/container separation, macOS Calendar
authorization and enumeration, the loopback callback, microphone capture and
playback, plus local vault recovery checks. Exercise the remaining advertised
features and record untested cases; chosen folders on external volumes and
revoked folder access still need follow-up QA. A development-signed app does
not verify App Store receipt or distribution-signature behavior.

After local sandbox QA passes, the release-mode command remains gated:

```sh
STORE_SANDBOX_READY=1 \
APPSTORE_APP_IDENTITY='3rd Party Mac Developer Application: Name (TEAMID)' \
APPSTORE_INSTALLER_IDENTITY='3rd Party Mac Developer Installer: Name (TEAMID)' \
APPSTORE_PROFILE='/secure/path/Hall-e-App-Store.provisionprofile' \
VERSION=0.5.0 BUILD_NUM=2026102009 ./scripts/package-mac-app-store.sh
```

The command creates a signed `.pkg` in `dist/`, validates its signatures,
payload, `/Applications` install destination, app identifier and version, and
writes a SHA-256 checksum. It **does not upload**. The distribution-signed app
may not launch directly before App Review, so do not use it as the local QA
artifact. Installed Store QA passed for build 2010 as described above. Public
submission still requires App Privacy answers based on real provider settings,
real screenshots, App Store Connect authorization/metadata, and an authorized
upload through Transporter or App Store Connect. The direct-download GitHub workflow remains
available on its existing tag/manual triggers, but it does not validate or
package this Store build. Hosted Actions are to remain undispatched until the
included allowance renews. When the separate direct-download release is ready,
its existing release workflow still applies to that distribution path.

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
- [Testing distribution builds of Mac apps (QA1884)](https://developer.apple.com/library/archive/qa/qa1884/)
- [Apple certificate types](https://developer.apple.com/help/account/certificates/certificates-overview/)
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [App Store Connect listing field limits](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
