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

# -A lets any app on THIS machine use the key without a per-build authorization
# prompt. That's appropriate for a local, self-signed dev cert used only to sign
# Hall-e (it isn't trusted by anyone else). This is what avoids the endless
# "codesign wants to access key" dialogs — no login password needed.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P halle -A \
  -T /usr/bin/codesign -T /usr/bin/security

# Trust for code signing is optional: locally built apps carry no quarantine, so
# Gatekeeper never evaluates them, and TCC keys off the (stable) designated
# requirement, not trust. Attempt it but don't fail if it needs GUI auth.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || true

# Signing works even if the cert isn't "valid" (trusted); confirm codesign can
# find the identity by name.
if security find-identity -p codesigning | grep -q "$CERT_NAME"; then
  echo "✓ Code-signing identity '$CERT_NAME' created (allow-all ACL — no build prompts)."
else
  echo "✗ Identity not found. See the manual Keychain Access steps in this script's header."
  exit 1
fi
