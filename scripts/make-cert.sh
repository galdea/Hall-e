#!/bin/bash
# One-time creation of the self-signed "Hall-e Dev" code-signing identity.
# A stable identity keeps TCC permissions and Keychain items valid across rebuilds
# (ad-hoc signing changes the designated requirement every build).
#
# If this script fails, create the certificate manually:
#   Keychain Access → Keychain Access menu → Certificate Assistant → Create a Certificate…
#   Name: "Hall-e Dev" · Identity Type: Self-Signed Root · Certificate Type: Code Signing
set -euo pipefail

CERT_NAME="Hall-e Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "✓ Code-signing identity '$CERT_NAME' already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ext.cnf" <<'EOF'
[req]
distinguished_name = dn
[dn]
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$CERT_NAME" \
  -config "$TMP/ext.cnf" -extensions ext >/dev/null 2>&1

openssl pkcs12 -export -legacy -out "$TMP/cert.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:halle -name "$CERT_NAME" 2>/dev/null \
|| openssl pkcs12 -export -out "$TMP/cert.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:halle -name "$CERT_NAME"

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P halle \
  -T /usr/bin/codesign -T /usr/bin/security

# Trust the cert for code signing (may show a GUI authorization prompt).
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null; then
  echo "⚠ Could not set trust automatically."
  echo "  Open Keychain Access → login → Certificates → '$CERT_NAME' → Get Info →"
  echo "  Trust → Code Signing: Always Trust."
fi

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "✓ Created code-signing identity '$CERT_NAME'."
  echo "  On first build, macOS will ask: codesign wants to use the key → click 'Always Allow'."
else
  echo "✗ Identity not yet valid. See the manual Keychain Access steps in this script's header."
  exit 1
fi
