#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

if [[ $# -ne 1 ]]; then
    print -u2 "usage: $0 <Oigo.app>"
    exit 64
fi

app="${1%/}"
if [[ ! -d "$app" ]]; then
    print -u2 "FAIL: app bundle does not exist: $app"
    exit 1
fi

required_version="26.0"
required_bundle_id="com.oigo.app"
required_executable_name="Oigo"
failures=0

fail() {
    print -u2 "FAIL: $1"
    failures=$((failures + 1))
}

pass() {
    print "GREEN: $1"
}

if [[ "${app:t}" != "Oigo.app" ]]; then
    fail "bundle name must be Oigo.app, found ${app:t}"
fi

parent="${app:h:t}"
if [[ "$parent" != "Release" ]]; then
    fail "bundle must be a Release product, found parent directory $parent"
fi

info="$app/Contents/Info.plist"
if [[ ! -f "$info" ]]; then
    fail "Info.plist is missing"
    print -u2 "FAILURES=$failures"
    exit 1
fi

/usr/bin/plutil -lint "$info" >/dev/null

plist_string() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$info" 2>/dev/null || true
}

plist_bool() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$info" 2>/dev/null || true
}

minimum_os="$(plist_string MinimumOSVersion)"
ls_minimum="$(plist_string LSMinimumSystemVersion)"
if [[ -z "$minimum_os" && -z "$ls_minimum" ]]; then
    fail "bundle Info.plist has neither MinimumOSVersion nor LSMinimumSystemVersion"
fi
if [[ -n "$minimum_os" && "$minimum_os" != "$required_version" ]]; then
    fail "MinimumOSVersion must be $required_version, found $minimum_os"
fi
if [[ -n "$ls_minimum" && "$ls_minimum" != "$required_version" ]]; then
    fail "LSMinimumSystemVersion must be $required_version, found $ls_minimum"
fi
if [[ "$minimum_os" == "$required_version" || "$ls_minimum" == "$required_version" ]]; then
    pass "minimum OS is $required_version"
fi

bundle_id="$(plist_string CFBundleIdentifier)"
if [[ "$bundle_id" == "$required_bundle_id" ]]; then
    pass "bundle identifier is $required_bundle_id"
else
    fail "CFBundleIdentifier must be $required_bundle_id, found ${bundle_id:-<missing>}"
fi

executable_name="$(plist_string CFBundleExecutable)"
if [[ "$executable_name" == "$required_executable_name" ]]; then
    pass "CFBundleExecutable is $required_executable_name"
else
    fail "CFBundleExecutable must be $required_executable_name, found ${executable_name:-<missing>}"
fi

short_version="$(plist_string CFBundleShortVersionString)"
bundle_version="$(plist_string CFBundleVersion)"
required_short_version="1.0.0"
if [[ "$short_version" == "$required_short_version" && -n "$bundle_version" ]]; then
    pass "bundle versions are $short_version ($bundle_version)"
else
    fail "CFBundleShortVersionString must be $required_short_version and CFBundleVersion must be present, found ${short_version:-<missing>} (${bundle_version:-<missing>})"
fi

apple_events_usage="$(plist_string NSAppleEventsUsageDescription)"
if [[ -n "$apple_events_usage" ]]; then
    pass "NSAppleEventsUsageDescription is present"
else
    fail "NSAppleEventsUsageDescription is missing"
fi

lsuielement="$(plist_bool LSUIElement)"
if [[ "$lsuielement" == "true" ]]; then
    pass "LSUIElement is true"
else
    fail "LSUIElement must be true, found ${lsuielement:-<missing>}"
fi

microphone_usage="$(plist_string NSMicrophoneUsageDescription)"
if [[ -n "$microphone_usage" ]]; then
    pass "NSMicrophoneUsageDescription is present"
else
    fail "NSMicrophoneUsageDescription is missing"
fi

icon_name="$(plist_string CFBundleIconName)"
if [[ "$icon_name" == "AppIcon" ]]; then
    pass "CFBundleIconName is AppIcon"
else
    fail "CFBundleIconName must be AppIcon, found ${icon_name:-<missing>}"
fi

assets_car="$app/Contents/Resources/Assets.car"
app_icon="$app/Contents/Resources/AppIcon.icns"
if [[ -s "$assets_car" ]]; then
    pass "production asset catalog is present"
else
    fail "production Assets.car is missing or empty"
fi
if [[ -s "$app_icon" ]]; then
    pass "production AppIcon.icns is present"
else
    fail "production AppIcon.icns is missing or empty"
fi

executable="$app/Contents/MacOS/$required_executable_name"
if [[ -x "$executable" ]]; then
    pass "executable exists at Contents/MacOS/$required_executable_name"
else
    fail "executable is missing or not executable: $executable"
fi

if [[ -x "$executable" ]]; then
    archs="$(/usr/bin/lipo -archs "$executable" 2>/dev/null || true)"
    if [[ "$archs" == "arm64" ]]; then
        pass "executable architecture is arm64"
    else
        fail "executable architecture must be exactly arm64, found ${archs:-<unknown>}"
    fi
fi

forbidden=()
while IFS= read -r path; do
    case "$path" in
        *.xctest|*/xctest|*/XCTest*|*/Tests/*|*.swift|*.dSYM|*/dSYM/*|*Test.bundle|*Gallery*|*gallery*|*Prototype*|*prototype*|*Fixture*|*fixture*)
            forbidden+="$path"
            ;;
    esac
done < <(/usr/bin/find "$app" \( -type f -o -type d \))

debug_artifacts=()
while IFS= read -r path; do
    debug_artifacts+="$path"
done < <(/usr/bin/find "$app" \( -name '*debug*' -o -name '*Debug*' -o -name '*.xctest' -o -name 'XCTest*' \) 2>/dev/null)

if (( ${#forbidden[@]} == 0 && ${#debug_artifacts[@]} == 0 )); then
    pass "bundle contains no gallery, prototype, fixture, test, or debug artifacts"
else
    fail "bundle contains test or debug artifacts: ${forbidden[*]} ${debug_artifacts[*]}"
fi

if [[ -d "$app/Contents/PlugIns" ]]; then
    fail "bundle contains PlugIns, which ordinary Release CI must not ship"
fi

repo_root="${0:A:h:h}"
if membership_error="$(
    /usr/bin/python3 "$repo_root/Scripts/check-xcode-source-membership.py" "$repo_root" 2>&1
)"; then
    pass "every production source is compiled into the correct Xcode target"
else
    fail "source membership drift: ${membership_error}"
fi

print "INCONCLUSIVE: microphone TCC is not exercised by bundle inspection"
print "INCONCLUSIVE: Speech assets and recognition are not exercised by bundle inspection"
print "INCONCLUSIVE: Accessibility permission is not exercised by bundle inspection"
print "INCONCLUSIVE: hardware capture devices are not exercised by bundle inspection"
print "INCONCLUSIVE: Developer ID signing, notarization, and Gatekeeper are not exercised by unsigned CI"
print "INCONCLUSIVE: clean-account dogfood is not exercised by hosted CI"

if (( failures > 0 )); then
    print -u2 "FAILURES=$failures"
    exit 1
fi

print "GREEN: Oigo.app bundle inspection"
exit 0
