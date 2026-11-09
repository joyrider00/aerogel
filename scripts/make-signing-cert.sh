#!/usr/bin/env bash
# One-time: creates a self-signed "Aerogel Local Signing" code-signing identity in your
# login keychain so rebuilt copies of Aerogel keep the same identity (no Keychain re-prompts).
set -euo pipefail
NAME="Aerogel Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "Already exists."; exit 0; fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/cfg" <<CFG
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/key.pem" -out "$W/cert.pem" -days 3650 -config "$W/cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$W/key.pem" -in "$W/cert.pem" -out "$W/id.p12" -passout pass:tmp -name "$NAME" 2>/dev/null
security import "$W/id.p12" -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
echo "Created \"$NAME\". scripts/build-app.sh will use it automatically."
