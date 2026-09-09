#!/bin/bash
# Create the native macOS drag-to-Applications disk image used for releases.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# == 2 ]] || { echo 'Usage: package-dmg.sh APP OUTPUT.dmg' >&2; exit 1; }
APP="$1"
OUTPUT="$2"
[[ -d "$APP" && "$APP" == *.app ]] || { echo 'APP must be an existing .app bundle' >&2; exit 1; }
[[ "$OUTPUT" == *.dmg ]] || { echo 'OUTPUT must end in .dmg' >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VOLUME_NAME="Hall-e $VERSION"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/halle-dmg.XXXXXX")"
SOURCE="$TEMP/source"
MOUNT="$TEMP/mount"
RW_DMG="$TEMP/Hall-e-rw.dmg"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then
    hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet || true
  fi
  rm -rf "$TEMP"
}
trap cleanup EXIT

mkdir -p "$SOURCE" "$MOUNT" "$(dirname "$OUTPUT")"
ditto "$APP" "$SOURCE/Hall-e.app"
ln -s /Applications "$SOURCE/Applications"
cat > "$SOURCE/Start here - Comienza aquí.txt" <<'README'
WELCOME TO HALL-E / BIENVENIDO A HALL-E

1. Drag Hall-e to Applications, then eject this disk image.
2. Open Hall-e from Applications and follow the four setup steps.
3. Allow the microphone and speech recognition. Try the short audio check.
4. Choose Start recording. For an online meeting, choose microphone + your
   meeting app, and join the call before recording.

Local transcription needs a compatible on-device language model. Setup checks
your Mac. Cloud providers are optional and require your own account and consent.

1. Arrastra Hall-e a Aplicaciones y expulsa esta imagen de disco.
2. Abre Hall-e desde Aplicaciones y sigue los cuatro pasos de configuración.
3. Autoriza el micrófono y el reconocimiento de voz. Prueba el audio.
4. Elige Iniciar grabación. Para una reunión en línea, selecciona micrófono +
   la app de la reunión y entra a la llamada antes de grabar.

La transcripción local necesita un modelo de idioma compatible en tu Mac.
La configuración lo revisa. Los proveedores en la nube son opcionales y
requieren tu propia cuenta y autorización.

Tell participants before recording. / Avisa a los participantes antes de grabar.

Updates and help / Actualizaciones y ayuda:
https://github.com/galdea/Hall-e/releases/latest
README
if [[ "$OUTPUT" != *-notarized.dmg ]]; then
  cat >> "$SOURCE/Start here - Comienza aquí.txt" <<'README'

THIS BUILD IS NOT APPLE-NOTARIZED / ESTA VERSIÓN NO ESTÁ NOTARIZADA POR APPLE
After checking the source of your download, try opening Hall-e. If macOS blocks
it, go to System Settings > Privacy & Security > Open Anyway, if offered.
Managed Macs may require help from your IT team. Do not disable Gatekeeper.

Luego de comprobar la procedencia de la descarga, intenta abrir Hall-e. Si macOS
lo bloquea, ve a Ajustes del Sistema > Privacidad y seguridad > Abrir de todos
modos, si aparece. Un Mac administrado puede necesitar apoyo de informática.

Apple's instructions / Instrucciones de Apple:
https://support.apple.com/102445
README
fi

# The Applications link works in a normal Finder window without automating
# Finder or asking the builder for Apple Events permission (including in CI).
hdiutil create -quiet -srcfolder "$SOURCE" -volname "$VOLUME_NAME" -fs HFS+ -format UDRW "$RW_DMG"
hdiutil attach "$RW_DMG" -quiet -readwrite -noverify -nobrowse -mountpoint "$MOUNT"
MOUNTED=1

if [[ -f BundleResources/AppIcon.icns ]] && xcrun --find SetFile >/dev/null 2>&1; then
  cp BundleResources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
  xcrun SetFile -a C "$MOUNT"
fi

sync
hdiutil detach "$MOUNT" -quiet
MOUNTED=0

rm -f "$OUTPUT"
hdiutil convert "$RW_DMG" -quiet -format UDZO -imagekey zlib-level=9 -o "$TEMP/final"
mv "$TEMP/final.dmg" "$OUTPUT"
hdiutil verify "$OUTPUT" >/dev/null
echo "Created $OUTPUT"
