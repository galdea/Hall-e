# Downloadable macOS releases

Hall-e ships as a native drag-to-Applications DMG plus a ZIP alternative. It
targets macOS 14.0 and later; system audio capture requires 14.2+. Choose `arm64`
for Apple silicon or `x86_64` for Intel. For the normal installation, open the
DMG, drag Hall-e to Applications, eject the disk image, and launch Hall-e from
Applications. Hall-e opens a four-step first-run guide, then its meeting workspace;
it also remains available in the menu bar. Microphone and other access prompts
still require user consent. No account or key is needed for supported local
transcription. Setup checks the language model and offers an optional audio test.

`VERSION=0.3.1 make release` builds both executables sequentially, bundles English
and Spanish strings, the Chrome extension, reminder sound, and dependency resource
bundles, signs the app ad-hoc, and creates versioned DMG and ZIP packages plus a
SHA-256 checksum for each in `dist/`. The DMG contains
`Hall-e.app`, an Applications drag target, and bilingual installation instructions. Use
`shasum -a 256 -c <package>.sha256` from `dist/` to verify a download. A checksum
detects corruption; it does not authenticate the publisher.

Release verification also opens each package independently and checks the exact
filename/version/status tuple, bundle build number, both executable architectures,
code signature, and the DMG Applications link. Notarized builds additionally
validate the stapled tickets and Gatekeeper assessment. The default build number
is the source commit timestamp, so rerunning the same commit for Apple silicon and
Intel produces the same meaningful bundle build number; CI uses the same rule.

Ad-hoc signing requires no personal certificate or Apple account. It is **not
Developer ID signing or notarization**. Downloaded ad-hoc apps may be blocked by
Gatekeeper; after checking the source and download, use System Settings → Privacy
& Security → Open Anyway if macOS offers it. Managed Macs may prohibit this.
Do not disable Gatekeeper globally. Ad-hoc updates may require renewed privacy or
Keychain approval. For the smoothest public installation, maintainers should use
Developer ID signing and notarization.

## Build options

Use a clean Xcode installation with Swift 6 (CI selects Xcode 26.2). `make build`,
`make test`, and `make app` no longer require local certificate/toolchain setup.
Only opt into the legacy local CLT repair when needed:
`TOOLCHAIN_WORKAROUND=1 make app` (also supported by build.sh/release.sh).
That existing repair script can report a necessary manual toolchain repair.

Environment options: `VERSION=X.Y.Z`, numeric `BUILD_NUM`, `ARCH=arm64|x86_64`,
`CONFIG=release|debug`, `BUILD_DIR`, and `JOBS` (default 4). Release archives use
release configuration by default. Do not run simultaneous builds sharing a build
or output directory. macOS 14 compatibility is a deployment target; test on a
clean macOS 14 machine before announcing a release, including permissions,
recording, localization, reminders, and Chrome extension installation.

## Optional Developer ID and notarization

With the certificate in your keychain:

```sh
SIGNING_MODE=developer-id SIGN_ID='Developer ID Application: Your Name (TEAMID)' \
  VERSION=0.3.1 ./scripts/release.sh
```

Both executables receive hardened runtime and secure timestamps; the main app
receives the audio-input entitlement. The DMG itself is also Developer ID signed.
This produces `developer-id` packages, which are still **not notarized**. To
notarize, also set `NOTARIZE=1`, `APPLE_ID`,
`APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD` (an app-specific password) in the
environment. Do not commit credentials. Packaging requires an Accepted response,
staples and validates the app ticket, creates and Developer ID signs the DMG,
notarizes and staples that DMG, and checks Gatekeeper for both. The final ZIP
contains the already-stapled app. Any failure stops packaging; there is no ad-hoc
fallback.

## CI and release tags

The workflow tests and packages native Apple silicon and Intel builds on PRs,
main pushes, manual dispatches, and `vX.Y.Z` tags. Each job uploads versioned DMGs,
ZIPs, and checksums as downloadable Actions artifacts. Both jobs run on
macOS 15 with a macOS 14 deployment target. These are
separate architecture builds, not universal binaries.

Runs for the same commit share a concurrency group. If a tag is pushed while the
same main-branch validation is still running, the tag run supersedes it instead of
spending a second full pair of runners. Completed main validation is retained;
required PR/main coverage is not skipped. Staging Actions artifacts expire after
seven days; tagged GitHub Release assets do not depend on that retention period.

By default all jobs use ad-hoc signing without secrets. To opt into notarized tag
builds set repository variable `RELEASE_NOTARIZE=1`; manual runs have a notarize
checkbox. Configure these repository secrets:

- `DEVELOPER_ID_SIGN_ID`: full Developer ID Application identity name.
- `DEVELOPER_ID_P12_BASE64`: base64-encoded certificate and private key export.
- `DEVELOPER_ID_P12_PASSWORD`: export password.
- `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`: notarization credentials.

The CI helper imports the certificate into a temporary keychain and removes it
on exit. Signing secrets are only passed to explicitly opted-in release steps,
never PR builds. Protect release tags and restrict who can manually run workflows.

After both architecture jobs pass tests, package verification, and fresh-profile
startup, a tag build creates a draft, uploads the verified DMGs, ZIPs, and checksums,
then **publishes the GitHub Release**. The DMG is the recommended download for
nontechnical users. A public repository and a published release are required for
anonymous downloads; Actions artifacts are staging outputs that generally require
sign-in and expire. Only the tag-triggered publish-release job has repository write
permission. It refuses to modify an already published release. Fixes use a new
version/tag. The workflow never changes repository visibility.

References: [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[GitHub runner images](https://github.com/actions/runner-images).

## Automated installation check

Each GitHub-hosted disposable macOS CI runner installs and launches both the ZIP and DMG through
the same fresh-profile check. For the DMG it verifies the Applications drag target,
copies the app out of the mounted image, and ejects it before launch. The check
then verifies the installed signature, launches through LaunchServices, and
confirms that the app remains running with a valid database, empty project
directory, and no recordings. Preferences and test data are reset before each
archive and restored after its process has stopped. This verifies first launch on both architectures.
Interactive microphone/system-audio permission prompts and a real call still
require a human check; CI does not grant those permissions.

## Updating and sharing

### Cloud connection checks (v0.3.1 and later)

For cloud setup, paste a provider key, select a Speechmatics region when applicable,
and choose **Save & test**. The key is saved only after a successful read-only
authentication check. Failed or cancelled replacement checks preserve the existing
key, and a concurrent change from another settings window is not overwritten.
Allow the provider to process audio separately, then make a short recording to
check end-to-end transcription. Authentication does not prove available credit or
model entitlement. Existing keys can be retested without replacing them.

The checks use [Deepgram's authentication endpoint](https://developers.deepgram.com/guides/fundamentals/authenticating)
and [Speechmatics' regional job-list authentication](https://docs.speechmatics.com/get-started/authentication).
They send no audio and do not create paid transcription jobs. The selected region
is part of Speechmatics verification and audio consent.

Pushing `main` produces CI staging artifacts; a version tag publishes installers
only after both architecture jobs pass. Redeploy the landing page with the new
versioned links only after both public downloads are available. Existing release
assets are preserved; v0.3.0 installers do not contain the connection-check flow.

### Installing an update

Use **Settings → About & support → Check for updates / share Hall-e** to open the
latest release. Share that public release link with colleagues. There is no
automatic background update installer. Quit Hall-e, replace the app in Applications,
and reopen it. Audio, transcripts, built-in notes, and provider settings remain in
the user's Library/Keychain; they are never bundled into a release.

For the first meeting, join the call before choosing **Start recording →
Microphone + your meeting app**. If app audio fails, Hall-e displays a microphone-only
warning and a retry action. The eight-second setup test checks your microphone
and, when enabled and supported, local recognition; it does not prove that remote
meeting audio is being captured. Permission prompts and live audio need checking
on the receiving Mac. On-device speech does not provide individual speaker labels
or automatic AI meeting summaries; those are optional integrations.
