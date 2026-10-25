#!/bin/sh
# Creates the self-signed code-signing certificate "Hexer Development" in the login keychain, so
# local builds (Scripts/bundle.sh) keep one identity from build to build. An ad-hoc signature
# changes with every build, and macOS then forgets the app's permissions (Screen Recording for
# -HexerSnapshot, for instance); with a certificate, the app's designated requirement is
# `identifier "com.nongdandev.hexer" and certificate leaf = H"…"`, which stays the same.
#
#   Scripts/dev_identity.sh            create the certificate (does nothing if it exists)
#   Scripts/dev_identity.sh --remove   delete it from the keychain
#
# No Apple Developer account is needed. The certificate is only for this Mac: a build signed with
# it is still "from an unidentified developer" on other Macs, like an ad-hoc one. Release builds
# on CI have no such certificate and stay ad hoc; a Developer ID goes in SIGN_IDENTITY.
set -eu
NAME="Hexer Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [ "${1:-}" = "--remove" ]; then
    security delete-identity -c "$NAME" "$KEYCHAIN" && echo "Removed \"$NAME\" from the login keychain"
    exit 0
fi

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" is already in the login keychain"
    exit 0
fi

TMP=$(mktemp -d -t hexer-identity)
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/req.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# The keychain importer only reads the older PKCS#12 algorithms, not OpenSSL 3's defaults.
openssl pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/identity.p12" \
    -passout pass:hexer -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
# codesign may use the key without asking; nothing else can.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P hexer -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\" in the login keychain (valid 10 years)."
echo "Scripts/bundle.sh now signs with it. macOS asks for Screen Recording once more for the next build, then remembers it."
