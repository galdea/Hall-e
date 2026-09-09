#!/bin/bash
# Build and package locally; never publishes a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."
export VERSION="${VERSION:-0.2.1}"
export ARCH="${ARCH:-$(uname -m)}"
export SIGNING_MODE="${SIGNING_MODE:-adhoc}"
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
ARCHIVE="Hall-e-${VERSION}-macOS14-${ARCH}-${STATUS}.zip"
# Recreate the final zip after stapling; never ship the submission archive.
rm -f "dist/$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$ARCHIVE"
(cd dist && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
echo "Packaged dist/$ARCHIVE"
