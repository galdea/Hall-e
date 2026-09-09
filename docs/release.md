# Downloadable macOS releases

Hall-e is packaged as a relocatable `Hall-e.app` inside a ZIP. It targets macOS
14.0 and later; system audio capture requires 14.2+. Choose `arm64` for Apple
silicon or `x86_64` for Intel. Extract the ZIP and drag Hall-e.app to Applications,
then launch it there. The app runs in the menu bar. Microphone and other access
prompts still require user consent.

`VERSION=0.2.0 make release` builds both executables sequentially, bundles English
and Spanish strings, the Chrome extension, reminder sound, and dependency resource
bundles, signs the app ad-hoc, and creates a versioned ZIP plus SHA-256 checksum in
`dist/`. Use `shasum -a 256 -c <archive>.sha256` from that directory to verify it.
A checksum detects corruption; it does not authenticate the publisher.

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
  VERSION=0.2.0 ./scripts/release.sh
```

Both executables receive hardened runtime and secure timestamps; the main app
receives the audio-input entitlement. This produces a `developer-id` archive,
which is still **not notarized**. To notarize, also set `NOTARIZE=1`, `APPLE_ID`,
`APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD` (an app-specific password) in the
environment. Do not commit credentials. Packaging requires an Accepted response,
staples and validates the ticket, checks Gatekeeper, then creates the final
`notarized` ZIP. Any failure stops packaging; there is no ad-hoc fallback.

## CI and release tags

The workflow tests and packages native Apple silicon and Intel builds on PRs,
main pushes, manual dispatches, and `vX.Y.Z` tags. Each job uploads versioned ZIPs
and checksums as downloadable Actions artifacts. Both jobs run on
macOS 15 with a macOS 14 deployment target. These are
separate architecture builds, not universal binaries.

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

Tag builds attach both architectures and checksums to a **draft GitHub Release**.
Review the assets and publish that draft when ready. A public repository and a
published release are required for anonymous downloads; Actions artifacts are
staging outputs that generally require sign-in and expire. Only the tag-triggered
draft-release job has repository write permission. The workflow never changes
repository visibility and never modifies an already published release.

References: [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[GitHub runner images](https://github.com/actions/runner-images).
