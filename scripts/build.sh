#!/bin/bash
# Build a relocatable macOS 14+ app. Ad-hoc signing needs no certificate.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${TOOLCHAIN_WORKAROUND:-0}" == 1 ]]; then
  ./scripts/fix-toolchain.sh
  export SWIFTPM_CUSTOM_LIBS_DIR="$PWD/.toolchain-fix"
fi
VERSION="${VERSION:-0.3.0}"
if [[ -z "${BUILD_NUM:-}" ]]; then
  # A commit timestamp is numeric, monotonic in normal release history, and
  # stable across architectures and reruns of the same source revision.
  BUILD_NUM="$(git show -s --format=%ct HEAD 2>/dev/null || date -u +%Y%m%d%H%M)"
fi
SIGN_ID="${SIGN_ID:--}"
SIGNING_MODE="${SIGNING_MODE:-adhoc}"
CONFIG="${CONFIG:-release}"
ARCH="${ARCH:-$(uname -m)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be X.Y.Z' >&2; exit 1; }
[[ "$BUILD_NUM" =~ ^[0-9]+$ ]] || { echo 'BUILD_NUM must be numeric' >&2; exit 1; }
case "$ARCH" in arm64|x86_64) ;; *) echo 'ARCH must be arm64 or x86_64' >&2; exit 1;; esac
case "$SIGNING_MODE" in
  adhoc) [[ "$SIGN_ID" == - ]] || { echo 'Use SIGNING_MODE=developer-id for a certificate' >&2; exit 1; } ;;
  developer-id) [[ "$SIGN_ID" == 'Developer ID Application: '* ]] || { echo 'Set SIGN_ID to a Developer ID Application identity' >&2; exit 1; } ;;
  *) echo 'Invalid SIGNING_MODE' >&2; exit 1;;
esac
export MACOSX_DEPLOYMENT_TARGET=14.0
BUILD_DIR="${BUILD_DIR:-$PWD/.build}"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd -P)"
args=(--disable-build-manifest-caching --scratch-path "$BUILD_DIR" --arch "$ARCH" -c "$CONFIG" -j "${JOBS:-4}")
swift build "${args[@]}" --product HallE
swift build "${args[@]}" --product CallCaptureNativeHost
BIN_DIR="$(swift build "${args[@]}" --show-bin-path)"

APP="dist/Hall-e.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/HallE" "$APP/Contents/MacOS/Hall-e"
cp "$BIN_DIR/CallCaptureNativeHost" "$APP/Contents/MacOS/CallCaptureNativeHost"
# Include all SwiftPM bundles, including dependency privacy/resources bundles.
shopt -s nullglob
for bundle in "$BIN_DIR/"*.bundle; do
  ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
RES="$APP/Contents/Resources/HallE_HallE.bundle"
for resource in en.lproj/Localizable.strings es.lproj/Localizable.strings GentleRing.wav CallCaptureExtension/manifest.json CallCaptureExtension/service-worker.js CallCaptureExtension/options.html CallCaptureExtension/options.js; do
  [[ -f "$RES/$resource" ]] || { echo "Missing bundled resource: $resource" >&2; exit 1; }
done
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# Notification sounds also resolve from the main bundle.
cp "$RES/GentleRing.wav" "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUM/" BundleResources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f BundleResources/AppIcon.icns ]]; then
  cp BundleResources/AppIcon.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP/Contents/Info.plist"
fi
sign_args=(--force --sign "$SIGN_ID")
if [[ "$SIGNING_MODE" == developer-id ]]; then
  sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" --identifier cl.gabriel.hall-e.callcapture "$APP/Contents/MacOS/CallCaptureNativeHost"
codesign "${sign_args[@]}" --entitlements BundleResources/Release.entitlements --identifier cl.gabriel.hall-e "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
for binary in Hall-e CallCaptureNativeHost; do
  [[ "$(lipo -archs "$APP/Contents/MacOS/$binary")" == "$ARCH" ]] || { echo 'Unexpected binary architecture' >&2; exit 1; }
done
echo "Built $APP ($VERSION build $BUILD_NUM, $ARCH, $SIGNING_MODE; not notarized)"
