#!/bin/bash
# Import an optional CI certificate into an ephemeral, isolated keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${SIGNING_MODE:-adhoc}" != developer-id ]]; then
  exec ./scripts/release.sh
fi
: "${DEVELOPER_ID_P12_BASE64:?Missing certificate}" "${DEVELOPER_ID_P12_PASSWORD:?Missing certificate password}"
TEMP="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/halle-sign.XXXXXX")"
KEYCHAIN="$TEMP/release.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
# Preserve the preexisting keychain search list for cleanup.
security list-keychains -d user > "$TEMP/keychains"
cleanup() {
  local previous=() line
  while IFS= read -r line; do
    line="${line#*\"}"; line="${line%\"*}"
    previous+=("$line")
  done < "$TEMP/keychains"
  security list-keychains -d user -s "${previous[@]}"
  security delete-keychain "$KEYCHAIN" || true
  rm -rf "$TEMP"
}
trap cleanup EXIT
printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$TEMP/certificate.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$TEMP/certificate.p12" -k "$KEYCHAIN" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN"
./scripts/release.sh
