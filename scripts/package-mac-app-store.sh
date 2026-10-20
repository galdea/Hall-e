#!/bin/bash
# Build a local sandbox QA app or a Mac App Store upload package. This script never uploads.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "Mac App Store package: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Required tool not found: $1"; }

[[ "$(uname -s)" == Darwin ]] || fail "Run this script on macOS with Xcode command-line tools installed."
for tool in swift codesign security productbuild pkgutil plutil python3 openssl; do require_command "$tool"; done

PACKAGE_MODE="${STORE_PACKAGE_MODE:-release}"
case "$PACKAGE_MODE" in
  qa)
    : "${STORE_QA_APP_IDENTITY:?Set STORE_QA_APP_IDENTITY to a valid Apple Development identity for local sandbox QA.}"
    : "${STORE_QA_PROFILE:?Set STORE_QA_PROFILE to a matching macOS development provisioning profile.}"
    APP_IDENTITY="$STORE_QA_APP_IDENTITY"
    PROFILE="$STORE_QA_PROFILE"
    case "$APP_IDENTITY" in
      "Apple Development: "*|"Mac Developer: "*) ;;
      *) fail "QA application identity must be an Apple Development / Mac Developer identity." ;;
    esac
    ;;
  release)
    # Apple QA1884 says modern Mac App Store distribution-signed apps cannot
    # be launched directly before App Review. Local sandbox QA uses a dev identity.
    [[ "${STORE_SANDBOX_READY:-0}" == 1 ]] || fail \
      "Store code review and clean sandbox QA are not signed off. See docs/store/mac-app-store.md. Set STORE_SANDBOX_READY=1 only after those blockers are resolved."
    : "${APPSTORE_APP_IDENTITY:?Set APPSTORE_APP_IDENTITY to a valid Mac App Store application signing identity.}"
    : "${APPSTORE_INSTALLER_IDENTITY:?Set APPSTORE_INSTALLER_IDENTITY to a valid Mac App Store installer identity.}"
    : "${APPSTORE_PROFILE:?Set APPSTORE_PROFILE to an explicit Mac App Store provisioning profile for cl.gabriel.hall-e.}"
    APP_IDENTITY="$APPSTORE_APP_IDENTITY"
    PROFILE="$APPSTORE_PROFILE"
    case "$APP_IDENTITY" in
      "3rd Party Mac Developer Application: "*|"Apple Distribution: "*) ;;
      *) fail "Application identity must be a Mac App Store / Apple Distribution identity." ;;
    esac
    case "$APPSTORE_INSTALLER_IDENTITY" in
      "3rd Party Mac Developer Installer: "*|"Mac Installer Distribution: "*) ;;
      *) fail "Installer identity must be a Mac App Store installer identity." ;;
    esac
    ;;
  *) fail "STORE_PACKAGE_MODE must be 'qa' or 'release'." ;;
esac
[[ -f "$PROFILE" ]] || fail "Provisioning profile not found: $PROFILE"

# Installer identities are not codesigning identities. Query both stores of
# identities without passing the codesigning filter for the installer cert.
security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$APP_IDENTITY\"" || \
  fail "Application identity is missing, invalid, or has no private key in the keychain."
if [[ "$PACKAGE_MODE" == release ]]; then
  security find-identity -v 2>/dev/null | grep -Fq "\"$APPSTORE_INSTALLER_IDENTITY\"" || \
    fail "Installer identity is missing, invalid, or has no private key in the keychain."
fi

APP_CERT_SHA1="$(security find-identity -v -p codesigning 2>/dev/null | python3 -c '
import re, sys
identity = sys.argv[1]
matches = [m.group(1).lower() for line in sys.stdin
           if (m := re.match(r"^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+\"(.*)\"$", line.strip()))
           and m.group(2) == identity]
if len(matches) != 1:
    raise SystemExit("Mac App Store package: expected exactly one matching application identity.")
print(matches[0])
' "$APP_IDENTITY")" || fail "Could not resolve the application signing certificate fingerprint."

# Export public certificates only, select the exact certificate paired with
# the signing identity above, and read its OU (Apple's Team ID). Never export a key.
certificate_team_id() {
  security find-certificate -a -p 2>/dev/null | python3 -c '
import hashlib, re, ssl, subprocess, sys
expected = sys.argv[1].lower()
pem_blocks = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", sys.stdin.read(), re.S)
matches = {ssl.PEM_cert_to_DER_cert(pem) for pem in pem_blocks
           if hashlib.sha1(ssl.PEM_cert_to_DER_cert(pem)).hexdigest() == expected}
if len(matches) != 1:
    raise SystemExit("Mac App Store package: could not find exactly one public certificate matching the identity fingerprint.")
result = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"],
                        input=ssl.DER_cert_to_PEM_cert(matches.pop()), text=True, capture_output=True, check=True)
subject = result.stdout.strip().split("=", 1)[-1]
teams = set(re.findall(r"(?:^|,)OU=([A-Z0-9]{10})(?:,|$)", subject))
if len(teams) != 1:
    raise SystemExit("Mac App Store package: signing certificate subject must contain exactly one 10-character Team ID OU.")
print(teams.pop())
' "$1"
}
APP_TEAM_ID="$(certificate_team_id "$APP_CERT_SHA1")" || fail "Could not verify the application certificate Team ID from its OU."
if [[ "$PACKAGE_MODE" == release ]]; then
  INSTALLER_CERT_SHA1="$(security find-identity -v 2>/dev/null | python3 -c '
import re, sys
identity = sys.argv[1]
matches = [m.group(1).lower() for line in sys.stdin
           if (m := re.match(r"^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+\"(.*)\"$", line.strip()))
           and m.group(2) == identity]
if len(matches) != 1:
    raise SystemExit("Mac App Store package: expected exactly one matching installer identity.")
print(matches[0])
' "$APPSTORE_INSTALLER_IDENTITY")" || fail "Could not resolve the installer signing certificate fingerprint."
  INSTALLER_TEAM_ID="$(certificate_team_id "$INSTALLER_CERT_SHA1")" || fail "Could not verify the installer certificate Team ID from its OU."
  [[ -n "$APP_TEAM_ID" && "$APP_TEAM_ID" == "$INSTALLER_TEAM_ID" ]] || \
    fail "Application and installer identities must belong to the same 10-character Team ID."
fi

TEMP="$(mktemp -d "${TMPDIR:-/tmp}/halle-store-package.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
security cms -D -i "$PROFILE" > "$TEMP/profile.plist" || fail "Could not decode the provisioning profile."
python3 - "$TEMP/profile.plist" "BundleResources/MacAppStore.entitlements" "$TEMP/app-entitlements.plist" \
  "$APP_TEAM_ID" "$APP_CERT_SHA1" "$PACKAGE_MODE" <<'PY' || exit 1
import datetime
import hashlib
import plistlib
import re
import sys

profile_path, candidate_path, output_path, expected_team, cert_sha1, package_mode = sys.argv[1:]
with open(profile_path, "rb") as source:
    profile = plistlib.load(source)
with open(candidate_path, "rb") as source:
    claimed = plistlib.load(source)
entitlements = profile.get("Entitlements")
if not isinstance(entitlements, dict):
    raise SystemExit("Mac App Store package: provisioning profile has no Entitlements dictionary.")
platforms = profile.get("Platform")
if not isinstance(platforms, list) or "OSX" not in platforms:
    raise SystemExit("Mac App Store package: provisioning profile must include the macOS platform (OSX).")
app_identifier = entitlements.get("com.apple.application-identifier")
if not isinstance(app_identifier, str):
    app_identifier = entitlements.get("application-identifier")
if not isinstance(app_identifier, str) or not re.fullmatch(r"[A-Z0-9]{10}\.cl\.gabriel\.hall-e", app_identifier):
    raise SystemExit("Mac App Store package: profile must authorize the exact macOS App ID cl.gabriel.hall-e.")
profile_team = entitlements.get("com.apple.developer.team-identifier")
team_ids = profile.get("TeamIdentifier") or []
if profile_team != expected_team or not team_ids or team_ids[0] != expected_team:
    raise SystemExit("Mac App Store package: profile Team ID does not match the signing certificate Team ID.")
if profile.get("ExpirationDate") is None or profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    raise SystemExit("Mac App Store package: provisioning profile has expired.")
get_task_allow = entitlements.get("com.apple.security.get-task-allow", entitlements.get("get-task-allow"))
if package_mode == "release":
    if profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
        raise SystemExit("Mac App Store package: profile is not an App Store distribution profile.")
    if get_task_allow is True:
        raise SystemExit("Mac App Store package: distribution profile unexpectedly permits debugging.")
else:
    if not profile.get("ProvisionedDevices"):
        raise SystemExit("Mac App Store package: QA development profile must authorize registered test Macs.")
    if profile.get("ProvisionsAllDevices"):
        raise SystemExit("Mac App Store package: QA requires a development profile, not an enterprise profile.")
certificates = profile.get("DeveloperCertificates")
if not isinstance(certificates, list) or not any(hashlib.sha1(cert).hexdigest() == cert_sha1 for cert in certificates):
    raise SystemExit("Mac App Store package: profile does not authorize the selected application signing certificate.")

# App ID and team ID are platform signing entitlements on macOS. Set them from
# the profile rather than guessing that the App ID prefix equals the Team ID.
claimed["com.apple.application-identifier"] = app_identifier
claimed["com.apple.developer.team-identifier"] = expected_team
with open(output_path, "wb") as destination:
    plistlib.dump(claimed, destination, fmt=plistlib.FMT_XML, sort_keys=True)
PY
plutil -lint "$TEMP/app-entitlements.plist" >/dev/null || fail "Generated signing entitlements are not a valid plist."

VERSION="${VERSION:-0.4.0}"
ARCH="${ARCH:-$(uname -m)}"
BUILD_NUM="${BUILD_NUM:-$(git show -s --format=%ct HEAD 2>/dev/null || date -u +%Y%m%d%H%M)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must be X.Y.Z."
[[ "$BUILD_NUM" =~ ^[0-9]+$ ]] || fail "BUILD_NUM must be numeric."

# The build selects Store-specific capabilities and assembles the app with
# ad-hoc signing; re-signing below applies the selected mode's profile.
EDITION=mac-app-store SIGNING_MODE=adhoc VERSION="$VERSION" BUILD_NUM="$BUILD_NUM" ARCH="$ARCH" ./scripts/build.sh
APP="dist/Hall-e.app"
[[ -d "$APP" ]] || fail "Build did not create $APP."
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$APP_ID" == cl.gabriel.hall-e ]] || fail "Unexpected bundle identifier: $APP_ID"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

[[ ! -e "$APP/Contents/MacOS/CallCaptureNativeHost" ]] || fail "Store edition unexpectedly contains the Chrome helper."
codesign --force --sign "$APP_IDENTITY" --timestamp \
  --entitlements "$TEMP/app-entitlements.plist" \
  --identifier "$APP_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements :- "$APP" > "$TEMP/signed-entitlements.plist" 2>/dev/null
plutil -lint "$TEMP/signed-entitlements.plist" >/dev/null || fail "Signed entitlement payload is not a valid plist."
python3 - "$TEMP/signed-entitlements.plist" "$TEMP/app-entitlements.plist" <<'PY' || exit 1
import plistlib
import sys
with open(sys.argv[1], "rb") as source:
    actual = plistlib.load(source)
with open(sys.argv[2], "rb") as source:
    expected = plistlib.load(source)
for key, value in expected.items():
    if actual.get(key) != value:
        raise SystemExit(f"Mac App Store package: signed entitlement mismatch for {key}.")
PY

mkdir -p dist
if [[ "$PACKAGE_MODE" == qa ]]; then
  QA_DIR="dist/qa"
  QA_APP="$QA_DIR/Hall-e-${VERSION}-b${BUILD_NUM}-MacAppStore-QA.app"
  [[ ! -e "$QA_APP" ]] || fail "QA output already exists: $QA_APP (remove it explicitly before rebuilding)."
  mkdir -p "$QA_DIR"
  ditto "$APP" "$QA_APP"
  codesign --verify --deep --strict --verbose=2 "$QA_APP"
  echo "Created local development-signed Store-configuration QA app: $QA_APP"
  echo "Copy it into /Applications on a registered test Mac and launch it locally. It is not an App Store distribution-signed or upload candidate."
  echo "No package, upload, or App Store submission was performed."
else
  PKG="dist/Hall-e-${VERSION}-MacAppStore.pkg"
  rm -f "$PKG" "$PKG.sha256"
  productbuild --sign "$APPSTORE_INSTALLER_IDENTITY" --component "$APP" /Applications "$PKG"
  pkgutil --check-signature "$PKG" | tee "$TEMP/pkg-signature.txt"
  grep -Fq "$APPSTORE_INSTALLER_IDENTITY" "$TEMP/pkg-signature.txt" || fail "Installer package signature does not match the requested identity."
  pkgutil --payload-files "$PKG" | grep -Fxq './Hall-e.app/Contents/Info.plist' || fail "Installer package payload does not contain Hall-e.app/Contents/Info.plist."
  pkgutil --expand "$PKG" "$TEMP/expanded-package"
  python3 - "$TEMP/expanded-package" "$APP_ID" "$VERSION" <<'PY' || fail "Installer package does not install the expected Hall-e app in /Applications."
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

expanded, expected_id, expected_version = sys.argv[1:]
packages = list(Path(expanded).glob("*.pkg/PackageInfo"))
for package_info in packages:
    root = ET.parse(package_info).getroot()
    bundles = [entry for entry in root.iter("bundle")
               if entry.attrib.get("id") == expected_id
               and entry.attrib.get("path", "").removeprefix("./") == "Hall-e.app"]
    if (root.tag == "pkg-info"
            and root.attrib.get("install-location") == "/Applications"
            and root.attrib.get("version") == expected_version
            and bundles):
        raise SystemExit(0)
raise SystemExit(1)
PY
  (cd dist && shasum -a 256 "$(basename "$PKG")" > "$(basename "$PKG").sha256" && shasum -a 256 -c "$(basename "$PKG").sha256")
  echo "Created $PKG for App Store Connect upload. No upload or App Store submission was performed."
fi
