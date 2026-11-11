#!/bin/bash
# Creates a self-signed code-signing certificate in your login keychain, once.
# build.sh signs with it when present, so macOS keeps Murmur's permissions across rebuilds.
# (macOS 27 does not honour Accessibility for ad-hoc signed apps.)
set -euo pipefail
NAME="${1:-Murmur Local Signing}"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "'$NAME' already exists."; exit 0; fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
PASS=$(uuidgen)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.conf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created '$NAME' in your login keychain."
