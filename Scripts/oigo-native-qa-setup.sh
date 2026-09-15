#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

typeset -A value
while (( $# > 0 )); do
    [[ $# -ge 2 && "$2" != --* ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
    key="${1#--}"
    [[ "$key" == (source-root|source-sha|app-bundle|qa-root|evidence-root|target-bundle) ]] || {
        print -u2 "ERROR unknown-argument"
        exit 64
    }
    [[ -z "${value[$key]-}" ]] || { print -u2 "ERROR duplicate-argument"; exit 64; }
    value[$key]="$2"
    shift 2
done
for key in source-root source-sha app-bundle qa-root evidence-root target-bundle; do
    [[ -n "${value[$key]-}" ]] || { print -u2 "ERROR missing-argument"; exit 64; }
done
source_root="${value[source-root]:A}"
source_sha="${value[source-sha]}"
app_bundle="${value[app-bundle]:A}"
qa_root="${value[qa-root]:A}"
evidence_root="${value[evidence-root]:A}"
target_bundle="${value[target-bundle]:A}"
[[ "$source_sha" =~ '^[0-9a-f]{40}$' && ( -d "$source_root/.git" || -f "$source_root/.git" ) ]] || {
    print -u2 "ERROR invalid-source"
    exit 1
}
[[ "$(git -C "$source_root" rev-parse --verify HEAD)" == "$source_sha" ]] || { print -u2 "ERROR source-sha-mismatch"; exit 1; }
git -C "$source_root" diff --quiet HEAD -- || { print -u2 "ERROR dirty-source"; exit 1; }
git -C "$source_root" diff --cached --quiet || { print -u2 "ERROR staged-source"; exit 1; }
[[ -d "$app_bundle" && "${app_bundle:t}" == "Oigo.app" ]] || { print -u2 "ERROR invalid-app-bundle"; exit 1; }
[[ -d "$target_bundle" ]] || { print -u2 "ERROR missing-target-bundle"; exit 1; }
[[ "$evidence_root" == "$qa_root/evidence" || "$evidence_root" == "$qa_root/evidence"/* ]] || {
    print -u2 "ERROR evidence-root-outside-qa-root"
    exit 1
}
[[ "$target_bundle" == "$qa_root"/* ]] || { print -u2 "ERROR target-outside-qa-root"; exit 1; }
app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist" 2>/dev/null || true)"
target_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_bundle/Contents/Info.plist" 2>/dev/null || true)"
target_field="$(/usr/libexec/PlistBuddy -c 'Print :OigoQATargetFieldIdentifier' "$target_bundle/Contents/Info.plist" 2>/dev/null || true)"
[[ "$app_id" == "com.oigo.app" && "$target_id" == "com.oigo.qa.target" && "$target_field" == "oigo.qa.target.field" ]] || {
    print -u2 "ERROR bundle-identity-mismatch"
    exit 1
}
mkdir -p "$qa_root" "$evidence_root" "$qa_root/app" "$qa_root/home/Library/Preferences" "$qa_root/fixtures/metadata" "$qa_root/session" "$qa_root/targets"
source_copy="$qa_root/source-$source_sha"
if [[ ! -e "$source_copy" ]]; then
    mkdir -p "$source_copy"
    git -C "$source_root" archive "$source_sha" | tar -x -C "$source_copy"
elif [[ ! -f "$source_copy/Package.swift" ]]; then
    print -u2 "ERROR invalid-source-copy"
    exit 1
fi
source_copy_sha="$source_root/Scripts/oigo-source-tree-sha256.sh"
source_copy_sha="$(zsh "$source_copy_sha" "$source_copy")"
staged_app="$qa_root/app/Oigo.app"
/usr/bin/ditto "$app_bundle" "$staged_app"
source_app_sha="$("$source_root/Scripts/oigo-bundle-sha256.sh" "$app_bundle" | sed -n 's/^APP_BUNDLE_SHA=//p')"
staged_app_sha="$("$source_root/Scripts/oigo-bundle-sha256.sh" "$staged_app" | sed -n 's/^APP_BUNDLE_SHA=//p')"
[[ -n "$source_app_sha" && "$staged_app_sha" == "$source_app_sha" ]] || { print -u2 "ERROR staged-app-sha-mismatch"; exit 1; }
staged_target="$qa_root/targets/OigoQATarget.app"
if [[ "$target_bundle" != "$staged_target" ]]; then
    /usr/bin/ditto "$target_bundle" "$staged_target"
fi
target_bundle_sha="$(shasum -a 256 "$staged_target/Contents/Info.plist" "$staged_target/Contents/MacOS/OigoQATarget" | shasum -a 256 | awk '{print "sha256:" $1}')"
/usr/bin/xcrun swiftc "$source_copy/Scripts/oigo-qa-ax-driver.swift" -framework AppKit -framework ApplicationServices -o "$qa_root/oigo-qa-ax-driver"
/usr/bin/xcrun swiftc "$source_copy/Scripts/oigo-native-key-event-driver.swift" -framework ApplicationServices -o "$qa_root/oigo-native-key-event-driver"
/usr/bin/xcrun swiftc "$source_copy/Scripts/oigo-native-permission-preflight.swift" -framework AVFoundation -framework ApplicationServices -framework CoreGraphics -framework Speech -o "$qa_root/oigo-native-permission-preflight"
HOME="$qa_root/home" zsh "$source_copy/Scripts/oigo-native-qa-shortcut.sh" --home "$qa_root/home" --bundle-id com.oigo.app --write-default --key-code 49 --modifiers shift,command > "$evidence_root/shortcut-setup.txt"
atomic_write() {
    local destination="$1"
    local temporary
    temporary="$(mktemp "${destination:h}/.oigo-setup.XXXXXX")"
    cat > "$temporary"
    /usr/bin/ruby -e 'File.open(ARGV.fetch(0), "r") { |file| file.fsync }' "$temporary"
    mv "$temporary" "$destination"
}
chflags nouchg "$qa_root/native-qa-marker.json" 2>/dev/null || true
atomic_write "$qa_root/native-qa-marker.json" <<< "$(jq -n --arg qa_root "$qa_root" --arg repository "$source_root" --arg attempt_dir "$evidence_root" --arg source_sha "$source_sha" --arg source_tree_sha "$source_copy_sha" --arg app_sha "$staged_app_sha" --arg target_bundle_id "$target_id" --arg target_field_id "$target_field" --arg target_bundle_sha "$target_bundle_sha" '{schema:1,qa_root:$qa_root,repository:$repository,attempt_dir:$attempt_dir,source_sha:$source_sha,source_tree_sha:$source_tree_sha,app_sha:$app_sha,target_bundle_id:$target_bundle_id,target_field_id:$target_field_id,target_bundle_sha:$target_bundle_sha}')"
chflags nouchg "$qa_root/native-qa-marker.json" 2>/dev/null || true
chmod 444 "$qa_root/native-qa-marker.json"
chflags uchg "$qa_root/native-qa-marker.json" 2>/dev/null || true
atomic_write "$qa_root/fixtures/metadata/fixture-metadata.json" <<< "$(jq -n --arg source_sha "$source_sha" --arg app_sha "$staged_app_sha" '{schema:1,source_sha:$source_sha,app_sha:$app_sha,fixtures:"external-public-ui-only"}')"
atomic_write "$evidence_root/setup-receipt.txt" <<EOF
SOURCE_SHA=$source_sha
APP_BUNDLE_SHA=$staged_app_sha
STAGED_APP=$staged_app
STAGED_TARGET=$qa_root/targets/OigoQATarget.app
EOF
print "QA_SETUP_READY=$qa_root"
