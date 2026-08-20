#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

repo_root="$(cd "${0:A:h}/.." && pwd)"
cd "$repo_root"

version="1.0.0"
artifact_name="Oigo-${version}-arm64.zip"
entitlements="$repo_root/Oigo/Oigo.entitlements"
derived="${OIGO_DERIVED_DATA:-$repo_root/.build/release-package}"
release_dir="${OIGO_RELEASE_DIR:-$repo_root/dist}"

missing=()

if [[ -z "${OIGO_CODESIGN_IDENTITY:-}" ]]; then
    missing+=("OIGO_CODESIGN_IDENTITY")
fi

has_notary_profile=0
if [[ -n "${OIGO_NOTARY_PROFILE:-}" ]]; then
    has_notary_profile=1
fi

has_notary_api_key=0
if [[ -n "${OIGO_NOTARY_KEY:-}" && -n "${OIGO_NOTARY_KEY_ID:-}" && -n "${OIGO_NOTARY_ISSUER:-}" ]]; then
    has_notary_api_key=1
fi

if (( has_notary_profile == 0 && has_notary_api_key == 0 )); then
    if [[ -z "${OIGO_NOTARY_PROFILE:-}" ]]; then
        missing+=("OIGO_NOTARY_PROFILE")
    fi
    if [[ -z "${OIGO_NOTARY_KEY:-}" ]]; then
        missing+=("OIGO_NOTARY_KEY")
    fi
    if [[ -z "${OIGO_NOTARY_KEY_ID:-}" ]]; then
        missing+=("OIGO_NOTARY_KEY_ID")
    fi
    if [[ -z "${OIGO_NOTARY_ISSUER:-}" ]]; then
        missing+=("OIGO_NOTARY_ISSUER")
    fi
fi

if (( ${#missing[@]} > 0 )); then
    print -u2 "FAIL: missing release credentials."
    print -u2 "Set OIGO_CODESIGN_IDENTITY and either OIGO_NOTARY_PROFILE or OIGO_NOTARY_KEY, OIGO_NOTARY_KEY_ID, and OIGO_NOTARY_ISSUER."
    print -u2 "Missing:"
    for name in $missing; do
        print -u2 "  $name"
    done
    exit 1
fi

if [[ ! -f "$entitlements" ]]; then
    print -u2 "FAIL: entitlements file is missing: $entitlements"
    exit 1
fi

mkdir -p "$derived" "$release_dir"
app="$derived/Build/Products/Release/Oigo.app"

xcodebuild \
    -project "$repo_root/Oigo.xcodeproj" \
    -scheme Oigo \
    -configuration Release \
    -sdk macosx \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

if [[ ! -d "$app" ]]; then
    print -u2 "FAIL: unsigned Release app was not produced at $app"
    exit 1
fi

zsh "$repo_root/Scripts/inspect-oigo-app-bundle.sh" "$app"

sign_identity="$OIGO_CODESIGN_IDENTITY"
while IFS= read -r binary; do
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$sign_identity" \
        --entitlements "$entitlements" \
        "$binary"
done < <(
    /usr/bin/find "$app" -type f -print0 \
        | /usr/bin/xargs -0 /usr/bin/file \
        | /usr/bin/awk -F': ' '/Mach-O/ { print $1 }'
)

/usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$sign_identity" \
    --entitlements "$entitlements" \
    "$app"

staging="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/oigo-release.XXXXXXXX")"
cleanup() {
    /bin/rm -rf "$staging"
}
trap cleanup EXIT

/usr/bin/ditto "$app" "$staging/Oigo.app"
notary_zip="$staging/Oigo-notarize.zip"
/usr/bin/ditto -c -k --keepParent "$staging/Oigo.app" "$notary_zip"

if [[ -n "${OIGO_NOTARY_PROFILE:-}" ]]; then
    /usr/bin/xcrun notarytool submit "$notary_zip" \
        --keychain-profile "$OIGO_NOTARY_PROFILE" \
        --wait
else
    /usr/bin/xcrun notarytool submit "$notary_zip" \
        --key "$OIGO_NOTARY_KEY" \
        --key-id "$OIGO_NOTARY_KEY_ID" \
        --issuer "$OIGO_NOTARY_ISSUER" \
        --wait
fi

/usr/bin/xcrun stapler staple "$staging/Oigo.app"

scan_root="$staging/Oigo.app"
forbidden="$(
    /usr/bin/find "$scan_root" \( \
        -path '*/Tests/*' -o \
        -path '*/.build/*' -o \
        -name '*sample*transcript*' -o \
        -name '*Sample*Transcript*' \
    \) -print
)"
if [[ -n "$forbidden" ]]; then
    print -u2 "FAIL: development-only paths found in the signed artifact:"
    print -u2 "$forbidden"
    exit 1
fi

cat > "$staging/INSTALL.txt" <<'EOF'
Install Oigo

1. Drag Oigo.app to /Applications.
2. Open Oigo.
3. Grant Microphone access when asked.
4. Grant Accessibility access if you want automatic paste.
5. Confirm Apple-managed speech assets for your language are installed.

Oigo is a menu-bar dictation app for macOS 26 or later on Apple silicon only.
See README.md and docs/privacy.md in the download source or repository.
EOF

artifact="$release_dir/$artifact_name"
/bin/rm -f "$artifact"
(
    cd "$staging"
    /usr/bin/zip -r "$artifact" Oigo.app INSTALL.txt
)

checksum="$artifact.sha256"
/usr/bin/shasum -a 256 "$artifact" | /usr/bin/awk '{ print $1 "  " $2 }' > "$checksum"

print "GREEN: wrote $artifact"
print "GREEN: wrote $checksum"
