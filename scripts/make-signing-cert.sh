#!/bin/bash
# Creates a self-signed code-signing certificate in your login keychain.
# Signing every build with the same certificate means macOS keeps the
# Accessibility and Microphone permissions when you rebuild Shhh.
# Remove it any time in Keychain Access (search "Shhh Local Signing").
set -euo pipefail
NAME="Shhh Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Certificate \"$NAME\" already exists."
  exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:shhh -name "$NAME" 2>/dev/null
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P shhh -T /usr/bin/codesign
echo "Created \"$NAME\"."
