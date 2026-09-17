#!/bin/zsh
set -euo pipefail

if [[ $# -ne 0 ]]; then
    print "usage: $0"
    print "Builds and installs Oigo using OIGO_CODESIGN_IDENTITY (default: Oigo Local). Quit Oigo before installing."
    [[ "$1" == --help && $# -eq 1 ]] && exit 0
    exit 64
fi

repo_root="$(cd "${0:A:h}/.." && pwd)"
cd "$repo_root"

identity="${OIGO_CODESIGN_IDENTITY:-Oigo Local}"
if [[ "$identity" == - ]] || ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v name="$identity" '
    $2 == name || index($0, "\"" name "\"") { found = 1 }
    END { exit !found }
'; then
    print -u2 "FAIL: A stable code-signing identity is required. Run Scripts/setup-oigo-local-signing.sh or set OIGO_CODESIGN_IDENTITY to an existing identity."
    exit 1
fi

derived="${OIGO_DERIVED_DATA:-$repo_root/.build/xcode-dev}"
entitlements="$repo_root/Oigo/Oigo.entitlements"
app="$derived/Build/Products/Release/Oigo.app"
installed="/Applications/Oigo.app"

xcodebuild \
    -project Oigo.xcodeproj \
    -scheme Oigo \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

[[ -d "$app" ]] || {
    print -u2 "FAIL: Release app missing at $app"
    exit 1
}

/usr/bin/codesign --force --sign "$identity" --entitlements "$entitlements" "$app"
/usr/bin/codesign --verify --strict "$app"
"$repo_root/Scripts/inspect-oigo-app-bundle.sh" "$app"

if /usr/bin/pgrep -f '^/Applications/Oigo.app/Contents/MacOS/Oigo( |$)' >/dev/null; then
    print -u2 "FAIL: Quit Oigo, then rerun this installer. The signed build is ready at $app."
    exit 1
fi
if [[ -d "$installed" ]]; then
    if /usr/bin/codesign -dv "$installed" 2>&1 | /usr/bin/grep -Fxq 'Signature=adhoc'; then
        print "Replacing an ad-hoc build: macOS will require permission approval once for this stable identity."
    else
        requirement="$(/usr/bin/codesign -d -r- "$installed" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
        [[ -n "$requirement" ]] || {
            print -u2 "FAIL: Cannot read the installed app's signing identity."
            exit 1
        }
        /usr/bin/codesign --verify -R "=$requirement" "$app" || {
            print -u2 "FAIL: Signing identity changed. Refusing to replace Oigo and invalidate its permissions."
            exit 1
        }
    fi
fi

staged="/Applications/.Oigo-install-$$.app"
/usr/bin/ditto "$app" "$staged"
/usr/bin/codesign --verify --strict "$staged"
if [[ -d "$installed" ]]; then
    backup="$derived/install-backups/$(date +%Y%m%d-%H%M%S)-$$/Oigo.app"
    mkdir -p "${backup:h}"
    mv "$installed" "$backup"
fi
if ! mv "$staged" "$installed"; then
    [[ -n "${backup:-}" ]] && mv "$backup" "$installed"
    /usr/bin/trash "$staged"
    exit 1
fi
print "Installed $installed with stable identity: $identity"
if [[ -n "${backup:-}" ]]; then
    print "Previous app retained at $backup"
fi
