#!/bin/bash
# Builds HallE with SPM and assembles a signed Hall-e.app in dist/.
# Requires the one-time "Hall-e Dev" signing identity (scripts/make-cert.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

# Broken-CLT workaround (see scripts/fix-toolchain.sh)
./scripts/fix-toolchain.sh >/dev/null
export SWIFTPM_CUSTOM_LIBS_DIR="$PWD/.toolchain-fix"

VERSION="${VERSION:-0.1.0}"
BUILD_NUM="$(date +%Y%m%d%H%M)"
SIGN_ID="${SIGN_ID:-Hall-e Dev}"
CONFIG="${CONFIG:-release}"

swift build -c "$CONFIG" --product HallE
swift build -c "$CONFIG" --product CallCaptureNativeHost

APP="dist/Hall-e.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/HallE" "$APP/Contents/MacOS/Hall-e"
cp ".build/$CONFIG/CallCaptureNativeHost" "$APP/Contents/MacOS/CallCaptureNativeHost"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUM/" \
    BundleResources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f BundleResources/AppIcon.icns ]; then
  cp BundleResources/AppIcon.icns "$APP/Contents/Resources/"
fi
# SPM resource bundle, if the target ever declares resources
if [ -d ".build/$CONFIG/HallE_HallE.bundle" ]; then
  cp -R ".build/$CONFIG/HallE_HallE.bundle" "$APP/Contents/Resources/"
fi

codesign --force --sign "$SIGN_ID" --identifier cl.gabriel.hall-e.callcapture "$APP/Contents/MacOS/CallCaptureNativeHost"
codesign --force --sign "$SIGN_ID" --identifier cl.gabriel.hall-e "$APP"
codesign --verify --verbose=2 "$APP"
echo "✓ Built $APP ($VERSION build $BUILD_NUM)"
