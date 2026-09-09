#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

typeset -A value
while (( $# > 0 )); do
    [[ $# -ge 2 && "$2" != --* ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
    key="${1#--}"
    [[ "$key" == (profile|source-root|source-sha|manifest-sha|app|target|ax-driver|key-driver|output) ]] || {
        print -u2 "ERROR unknown-argument"
        exit 64
    }
    [[ -z "${value[$key]-}" ]] || { print -u2 "ERROR duplicate-argument"; exit 64; }
    value[$key]="$2"
    shift 2
done
for key in profile source-root source-sha manifest-sha app target ax-driver key-driver output; do
    [[ -n "${value[$key]-}" ]] || { print -u2 "ERROR missing-argument"; exit 64; }
done
source_root="${value[source-root]:A}"
manifest="$source_root/Scripts/oigo-native-qa-permission-profiles.tsv"
[[ -d "$source_root" && -f "$manifest" && "${value[source-sha]}" =~ '^[0-9a-f]{40}$' ]] || {
    print -u2 "ERROR invalid-source"
    exit 1
}
actual_manifest_sha="$(shasum -a 256 "$manifest" | awk '{print $1}')"
[[ "${value[manifest-sha]}" == "$actual_manifest_sha" ]] || { print -u2 "ERROR manifest-sha-mismatch"; exit 1; }
row="$(awk -F '\t' -v profile="${value[profile]}" '$1 == profile { print; found++ } END { if (found != 1) exit 1 }' "$manifest")" || {
    print -u2 "ERROR unknown-profile"
    exit 64
}
IFS=$'\t' read -r profile expected_account expected_uid app_bundle_id target_bundle_id ax_id ax_source ax_source_sha key_id key_source key_source_sha expected_microphone expected_speech expected_accessibility expected_assets expected_input <<< "$row"
[[ "$profile" == "${value[profile]}" && "$expected_uid" =~ '^[0-9]+$' ]] || { print -u2 "ERROR invalid-profile-row"; exit 1; }
observed_account="$(id -un)"
observed_uid="$(id -u)"
account_matches=true
if [[ "$observed_account" != "$expected_account" || "$observed_uid" != "$expected_uid" ]]; then
    account_matches=false
fi
app="${value[app]:A}"
target="${value[target]:A}"
ax_driver="${value[ax-driver]:A}"
key_driver="${value[key-driver]:A}"
[[ -d "$app" && -d "$target" && -x "$ax_driver" && -x "$key_driver" ]] || { print -u2 "ERROR missing-identity"; exit 1; }
observed_app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
observed_target_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)"
[[ "$observed_app_id" == "$app_bundle_id" && "$observed_target_id" == "$target_bundle_id" ]] || {
    print -u2 "ERROR bundle-identity-mismatch"
    exit 1
}
[[ "${ax_driver:t}" == "$ax_id" && "${key_driver:t}" == "$key_id" ]] || { print -u2 "ERROR driver-identity-mismatch"; exit 1; }
actual_ax_source_sha="$(shasum -a 256 "$source_root/$ax_source" | awk '{print $1}')"
actual_key_source_sha="$(shasum -a 256 "$source_root/$key_source" | awk '{print $1}')"
[[ "$actual_ax_source_sha" == "$ax_source_sha" && "$actual_key_source_sha" == "$key_source_sha" ]] || {
    print -u2 "ERROR driver-source-sha-mismatch"
    exit 1
}
output="${value[output]:A}"
output_parent="${output:h}"
[[ -d "$output_parent" && ! -L "$output_parent" && "$(stat -f '%u' "$output_parent")" == "$(id -u)" ]] || {
    print -u2 "ERROR unsafe-output-parent"
    exit 1
}
[[ ! -e "$output" ]] || { print -u2 "ERROR receipt-exists"; exit 1; }
body="$(mktemp "${output:h}/.permission-profile-body.XXXXXX")"
temporary="$(mktemp "${output:h}/.permission-profile-receipt.XXXXXX")"
trap 'rm -f "$body" "$temporary"' EXIT INT TERM
{
    print "ACCESSIBILITY_EXPECTED=$expected_accessibility"
    print "APP_BUNDLE_ID=$observed_app_id"
    print "APP_BUNDLE_SHA=$($source_root/Scripts/oigo-bundle-sha256.sh "$app" | sed -n 's/^APP_BUNDLE_SHA=//p')"
    print "ASSETS_EXPECTED=$expected_assets"
    print "AX_DRIVER_ID=${ax_driver:t}"
    print "AX_DRIVER_SHA=sha256:$(shasum -a 256 "$ax_driver" | awk '{print $1}')"
    print "INPUT_EXPECTED=$expected_input"
    print "KEY_DRIVER_ID=${key_driver:t}"
    print "KEY_DRIVER_SHA=sha256:$(shasum -a 256 "$key_driver" | awk '{print $1}')"
    print "MICROPHONE_EXPECTED=$expected_microphone"
    print "OBSERVED_ACCOUNT=$observed_account"
    print "OBSERVED_UID=$observed_uid"
    print "EXPECTED_ACCOUNT=$expected_account"
    print "EXPECTED_UID=$expected_uid"
    print "PERMISSION_PROFILE=$profile"
    print "PERMISSION_PROFILE_MANIFEST_SHA=sha256:$actual_manifest_sha"
    print "SOURCE_SHA=${value[source-sha]}"
    print "SPEECH_EXPECTED=$expected_speech"
    print "TARGET_BUNDLE_ID=$observed_target_id"
} | LC_ALL=C sort > "$body"
receipt_sha="$(shasum -a 256 "$body" | awk '{print $1}')"
cp "$body" "$temporary"
print "PERMISSION_PROFILE_RECEIPT_SHA=sha256:$receipt_sha" >> "$temporary"
/usr/bin/ruby -e 'File.open(ARGV.fetch(0), "r") { |file| file.fsync }' "$temporary"
mv -f "$temporary" "$output"
trap - EXIT INT TERM
rm -f "$body"
print "PERMISSION_PROFILE_RECEIPT_SHA=sha256:$receipt_sha"
if ! $account_matches; then
    print -u2 "ERROR profile-account-mismatch"
    exit 2
fi
