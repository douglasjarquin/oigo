#!/bin/zsh
set -euo pipefail

repo_root="$(cd "${0:A:h}/.." && pwd)"
cd "$repo_root"

derived="${OIGO_DERIVED_DATA:-$repo_root/.build/xcode-dev}"
entitlements="$repo_root/Oigo/Oigo.entitlements"
app="$derived/Build/Products/Debug/Oigo.app"

xcodebuild \
    -project Oigo.xcodeproj \
    -scheme Oigo \
    -configuration Debug \
    -derivedDataPath "$derived" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    build

[[ -d "$app" ]] || {
    print -u2 "FAIL: Debug app missing at $app"
    exit 1
}

codesign --force --sign - --entitlements "$entitlements" --deep "$app"

ditto "$app" /Applications/Oigo.app
print "Installed /Applications/Oigo.app with audio-input entitlement"
