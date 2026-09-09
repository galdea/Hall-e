#!/bin/bash
# Verify release contents independently of the packaging step.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# == 1 && -f "$1" ]] || { echo 'Pass one release ZIP or DMG.' >&2; exit 1; }
PACKAGE="$1"
: "${VERSION:?Set VERSION}" "${ARCH:?Set ARCH}" "${PACKAGE_STATUS:?Set PACKAGE_STATUS}"
case "$ARCH" in arm64|x86_64) ;; *) echo 'ARCH must be arm64 or x86_64' >&2; exit 1;; esac
case "$PACKAGE_STATUS" in adhoc|developer-id|notarized) ;; *) echo 'Invalid PACKAGE_STATUS' >&2; exit 1;; esac

TEMP="$(mktemp -d "${TMPDIR:-/tmp}/halle-verify.XXXXXX")"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then
    hdiutil detach "$TEMP/mount" -quiet || hdiutil detach "$TEMP/mount" -force -quiet || true
  fi
  rm -rf "$TEMP"
}
trap cleanup EXIT

case "$PACKAGE" in
  *.zip)
    EXT=zip
    mkdir -p "$TEMP/unpacked"
    ditto -x -k "$PACKAGE" "$TEMP/unpacked"
    APP="$TEMP/unpacked/Hall-e.app"
    ;;
  *.dmg)
    EXT=dmg
    hdiutil verify "$PACKAGE" >/dev/null
    mkdir -p "$TEMP/mount"
    hdiutil attach "$PACKAGE" -quiet -readonly -noverify -nobrowse -mountpoint "$TEMP/mount"
    MOUNTED=1
    APP="$TEMP/mount/Hall-e.app"
    [[ -L "$TEMP/mount/Applications" && "$(readlink "$TEMP/mount/Applications")" == /Applications ]] || {
      echo 'DMG is missing the Applications drag target' >&2; exit 1;
    }
    ;;
  *) echo 'Release package must be a ZIP or DMG' >&2; exit 1;;
esac

EXPECTED_NAME="Hall-e-${VERSION}-macOS14-${ARCH}-${PACKAGE_STATUS}.${EXT}"
[[ "$(basename "$PACKAGE")" == "$EXPECTED_NAME" ]] || {
  echo "Unexpected package name: expected $EXPECTED_NAME" >&2; exit 1;
}
[[ -d "$APP" ]] || { echo 'Hall-e.app is missing from release package' >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" == "$VERSION" ]] || {
  echo 'Bundle version does not match package version' >&2; exit 1;
}
if [[ -n "${BUILD_NUM:-}" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" == "$BUILD_NUM" ]] || {
    echo 'Bundle build number does not match expected build number' >&2; exit 1;
  }
fi

codesign --verify --deep --strict "$APP"
SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
case "$PACKAGE_STATUS" in
  adhoc)
    grep -q '^Signature=adhoc$' <<<"$SIGNATURE_INFO" || { echo 'Expected an ad-hoc app signature' >&2; exit 1; }
    ;;
  developer-id|notarized)
    grep -q '^Authority=Developer ID Application:' <<<"$SIGNATURE_INFO" || {
      echo 'Expected a Developer ID Application signature' >&2; exit 1;
    }
    ;;
esac

for binary in Hall-e CallCaptureNativeHost; do
  [[ "$(lipo -archs "$APP/Contents/MacOS/$binary")" == "$ARCH" ]] || {
    echo "Unexpected architecture for $binary" >&2; exit 1;
  }
done

if [[ "$EXT" == dmg && "$PACKAGE_STATUS" != adhoc ]]; then
  codesign --verify "$PACKAGE"
fi
if [[ "$PACKAGE_STATUS" == notarized ]]; then
  xcrun stapler validate "$APP" >/dev/null
  spctl --assess --type execute "$APP"
  if [[ "$EXT" == dmg ]]; then
    xcrun stapler validate "$PACKAGE" >/dev/null
    spctl --assess --type open --context context:primary-signature "$PACKAGE"
  fi
fi

echo "Verified $(basename "$PACKAGE"): $VERSION build ${BUILD_NUM:-unknown}, $ARCH, $PACKAGE_STATUS"
