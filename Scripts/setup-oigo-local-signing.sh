#!/bin/zsh
set -euo pipefail
umask 077

if [[ $# -ne 0 ]]; then
    print "usage: $0"
    print "Creates the Oigo Local code-signing identity in the login keychain, once."
    [[ "$1" == --help && $# -eq 1 ]] && exit 0
    exit 64
fi

identity="Oigo Local"
keychain="$HOME/Library/Keychains/login.keychain-db"
if /usr/bin/security find-identity -v -p codesigning "$keychain" | /usr/bin/grep -Fq "\"$identity\""; then
    print "Ready: $identity"
    exit 0
fi
if /usr/bin/security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
    print -u2 "FAIL: $identity already exists but is not usable. Check its private key, expiry, and code-signing trust in Keychain Access."
    exit 1
fi

scratch="$(mktemp -d "${TMPDIR%/}/oigo-signing.XXXXXX")"
trap '/usr/bin/trash "$scratch"' EXIT
openssl req -x509 -newkey rsa:2048 -noenc \
    -keyout "$scratch/key.pem" -out "$scratch/cert.pem" -days 3650 \
    -subj "/CN=$identity" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    >"$scratch/openssl.log" 2>&1
wrapping_password="$(openssl rand -hex 32)"
openssl pkcs12 -export -legacy -macalg sha1 \
    -out "$scratch/identity.p12" -inkey "$scratch/key.pem" -in "$scratch/cert.pem" \
    -passout stdin -name "$identity" <<< "$wrapping_password"
/usr/bin/security import "$scratch/identity.p12" -k "$keychain" \
    -P "$wrapping_password" -x -T /usr/bin/codesign
unset wrapping_password
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign \
    -k "$keychain" "$scratch/cert.pem"
/usr/bin/security find-identity -v -p codesigning "$keychain" | /usr/bin/grep -F "\"$identity\""
print "Ready: $identity. Use Scripts/install-oigo-dev.sh for subsequent builds."
