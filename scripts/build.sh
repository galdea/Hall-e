#!/bin/bash
# Builds HallE with SPM and assembles a signed Hall-e.app in dist/.
# Requires the one-time "Hall-e Dev" signing identity (scripts/make-cert.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

# Broken-CLT workaround (see scripts/fix-toolchain.sh)
./scripts/fix-toolchain.sh >/dev/null
export SWIFTPM_CUSTOM_LIBS_DIR="$(cd .toolchain-fix && pwd -P)"

VERSION="${VERSION:-0.1.0}"
BUILD_NUM="$(date +%Y%m%d%H%M)"
SIGN_ID="${SIGN_ID:-Hall-e Dev}"
CONFIG="${CONFIG:-release}"
# Canonical paths prevent Swift's module cache from seeing the same build
# directory under two names when packaging from an isolated worktree.
BUILD_DIR="${BUILD_DIR:-$PWD/.build}"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd -P)"

swift build --scratch-path "$BUILD_DIR" --disable-build-manifest-caching -j 4 -c "$CONFIG" --product HallE
swift build --scratch-path "$BUILD_DIR" --disable-build-manifest-caching -j 4 -c "$CONFIG" --product CallCaptureNativeHost

APP="dist/Hall-e.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/$CONFIG/HallE" "$APP/Contents/MacOS/Hall-e"
cp "$BUILD_DIR/$CONFIG/CallCaptureNativeHost" "$APP/Contents/MacOS/CallCaptureNativeHost"
cp "Sources/HallE/Resources/GentleRing.wav" "$APP/Contents/Resources/GentleRing.wav"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUM/" \
    BundleResources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f BundleResources/AppIcon.icns ]; then
  cp BundleResources/AppIcon.icns "$APP/Contents/Resources/"
fi
# SPM resource bundle, if the target ever declares resources
if [ -d "$BUILD_DIR/$CONFIG/HallE_HallE.bundle" ]; then
  cp -R "$BUILD_DIR/$CONFIG/HallE_HallE.bundle" "$APP/Contents/Resources/"
fi

codesign --force --sign "$SIGN_ID" --identifier cl.gabriel.hall-e.callcapture "$APP/Contents/MacOS/CallCaptureNativeHost"
codesign --force --sign "$SIGN_ID" --identifier cl.gabriel.hall-e "$APP"
codesign --verify --verbose=2 "$APP"
echo "✓ Built $APP ($VERSION build $BUILD_NUM)"
