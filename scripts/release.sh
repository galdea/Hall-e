#!/bin/bash
# Build and package locally; never publishes a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."
export VERSION="${VERSION:-0.3.2}"
export ARCH="${ARCH:-$(uname -m)}"
export SIGNING_MODE="${SIGNING_MODE:-adhoc}"
if [[ -z "${BUILD_NUM:-}" ]]; then
  export BUILD_NUM="$(git show -s --format=%ct HEAD 2>/dev/null || date -u +%Y%m%d%H%M)"
else
  export BUILD_NUM
fi
NOTARIZE="${NOTARIZE:-0}"
case "$NOTARIZE" in 0|1) ;; *) echo 'NOTARIZE must be 0 or 1' >&2; exit 1;; esac
if [[ "$NOTARIZE" == 1 ]]; then
  [[ "$SIGNING_MODE" == developer-id ]] || { echo 'Notarization requires Developer ID signing' >&2; exit 1; }
  : "${APPLE_ID:?Set APPLE_ID}" "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}" "${APPLE_APP_PASSWORD:?Set APPLE_APP_PASSWORD}"
fi
./scripts/build.sh
APP=dist/Hall-e.app
STATUS="$SIGNING_MODE"
if [[ "$NOTARIZE" == 1 ]]; then
  SUBMISSION="$(mktemp -d "${TMPDIR:-/tmp}/halle-notary.XXXXXX")"
  trap 'rm -rf "$SUBMISSION"' EXIT
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION/submit.zip"
  xcrun notarytool submit "$SUBMISSION/submit.zip" --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait --output-format plist > "$SUBMISSION/result.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$SUBMISSION/result.plist")" == Accepted ]] || {
    cat "$SUBMISSION/result.plist" >&2; exit 1;
  }
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  STATUS=notarized
fi

ZIP="Hall-e-${VERSION}-macOS14-${ARCH}-${STATUS}.zip"
DMG="Hall-e-${VERSION}-macOS14-${ARCH}-${STATUS}.dmg"
rm -f "dist/$ZIP" "dist/$ZIP.sha256" "dist/$DMG" "dist/$DMG.sha256"

# Recreate the final ZIP after stapling; never ship the notarization submission.
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$ZIP"
./scripts/package-dmg.sh "$APP" "dist/$DMG"

if [[ "$SIGNING_MODE" == developer-id ]]; then
  codesign --force --sign "$SIGN_ID" --timestamp "dist/$DMG"
fi

if [[ "$NOTARIZE" == 1 ]]; then
  # The app is notarized above so the ZIP contains a stapled app. Notarize and
  # staple the DMG itself as well for the smoothest drag-to-Applications path.
  xcrun notarytool submit "dist/$DMG" --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait --output-format plist > "$SUBMISSION/dmg-result.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$SUBMISSION/dmg-result.plist")" == Accepted ]] || {
    cat "$SUBMISSION/dmg-result.plist" >&2; exit 1;
  }
  xcrun stapler staple "dist/$DMG"
  xcrun stapler validate "dist/$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "dist/$DMG"
fi

export PACKAGE_STATUS="$STATUS"
./scripts/verify-release.sh "dist/$ZIP"
./scripts/verify-release.sh "dist/$DMG"
for package in "$ZIP" "$DMG"; do
  (cd dist && shasum -a 256 "$package" > "$package.sha256" && shasum -a 256 -c "$package.sha256")
done
echo "Packaged dist/$ZIP and dist/$DMG"
