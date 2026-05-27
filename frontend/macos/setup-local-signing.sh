#!/usr/bin/env bash
set -euo pipefail

IDENTITY_NAME="drWisper Local Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL_BIN="$(command -v openssl)"
P12_PASSWORD="drwisper-local"

if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -Fq "\"$IDENTITY_NAME\""; then
  echo "Code-signing identity already exists: $IDENTITY_NAME"
  exit 0
fi

WORK_DIR="$(/usr/bin/mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

CERT_CONFIG="$WORK_DIR/cert.conf"
KEY_PATH="$WORK_DIR/drwisper-local-signing.key"
CERT_PATH="$WORK_DIR/drwisper-local-signing.crt"
P12_PATH="$WORK_DIR/drwisper-local-signing.p12"

cat > "$CERT_CONFIG" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = codesign_ext
prompt = no

[req_distinguished_name]
CN = $IDENTITY_NAME

[codesign_ext]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

"$OPENSSL_BIN" req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -days 3650 \
  -keyout "$KEY_PATH" \
  -out "$CERT_PATH" \
  -config "$CERT_CONFIG" \
  >/dev/null 2>&1

"$OPENSSL_BIN" pkcs12 \
  -export \
  -legacy \
  -inkey "$KEY_PATH" \
  -in "$CERT_PATH" \
  -out "$P12_PATH" \
  -passout "pass:$P12_PASSWORD" \
  >/dev/null 2>&1

/usr/bin/security import "$P12_PATH" \
  -k "$KEYCHAIN" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  >/dev/null

/usr/bin/security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN" \
  "$CERT_PATH"

echo "Created code-signing identity: $IDENTITY_NAME"
echo "Next: run ./update-and-run.sh, then grant Accessibility once for ~/Applications/drWisper.app."
