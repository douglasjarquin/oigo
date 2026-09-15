#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

typeset -A value
while (( $# > 0 )); do
    [[ $# -ge 2 && "$2" != --* ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
    key="${1#--}"
    [[ "$key" == (profile|source-root|app|app-source-sha|app-sha|qa-root|evidence-root|frontmost-app|target-field-id) ]] || {
        print -u2 "ERROR unknown-argument"
        exit 64
    }
    [[ -z "${value[$key]-}" ]] || { print -u2 "ERROR duplicate-argument"; exit 64; }
    value[$key]="$2"
    shift 2
done
for key in profile source-root app app-source-sha app-sha qa-root evidence-root frontmost-app target-field-id; do
    [[ -n "${value[$key]-}" ]] || { print -u2 "ERROR missing-argument"; exit 64; }
done
source_root="${value[source-root]:A}"
app="${value[app]:A}"
qa_root="${value[qa-root]:A}"
evidence_root="${value[evidence-root]:A}"
target="${value[frontmost-app]:A}"
[[ -d "$source_root" && "$source_root" == "$qa_root/source-${value[app-source-sha]}" ]] || { print -u2 "ERROR source-sha-mismatch"; exit 1; }
[[ -f "$qa_root/native-qa-marker.json" && -d "$app" && -d "$target" ]] || { print -u2 "ERROR invalid-qa-root"; exit 1; }
[[ "${value[app-source-sha]}" =~ '^[0-9a-f]{40}$' && "${value[app-sha]}" =~ '^sha256:[0-9a-f]{64}$' ]] || { print -u2 "ERROR invalid-sha"; exit 1; }
jq -e --arg qa_root "$qa_root" --arg source_sha "${value[app-source-sha]}" --arg app_sha "${value[app-sha]}" '.qa_root == $qa_root and .source_sha == $source_sha and .app_sha == $app_sha' "$qa_root/native-qa-marker.json" >/dev/null || { print -u2 "ERROR invalid-native-qa-marker"; exit 1; }
actual_app_sha="$("$source_root/Scripts/oigo-bundle-sha256.sh" "$app" | sed -n 's/^APP_BUNDLE_SHA=//p')"
[[ "$actual_app_sha" == "${value[app-sha]}" ]] || { print -u2 "ERROR app-sha-mismatch"; exit 1; }
target_field="$(/usr/libexec/PlistBuddy -c 'Print :OigoQATargetFieldIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)"
[[ "$target_field" == "${value[target-field-id]}" ]] || { print -u2 "ERROR target-field-mismatch"; exit 1; }
[[ "$evidence_root" == "$qa_root/evidence" || "$evidence_root" == "$qa_root/evidence"/* ]] || {
    print -u2 "ERROR evidence-root-outside-qa-root"
    exit 1
}
[[ "$app" == "$qa_root"/* && "$target" == "$qa_root"/* ]] || { print -u2 "ERROR bundle-outside-qa-root"; exit 1; }
manifest="$source_root/Scripts/oigo-native-qa-permission-profiles.tsv"
manifest_sha="$(shasum -a 256 "$manifest" | awk '{print $1}')"
profile_row="$(awk -F '\t' -v profile="${value[profile]}" '$1 == profile { print; found++ } END { if (found != 1) exit 1 }' "$manifest")" || { print -u2 "ERROR unknown-profile"; exit 64; }
IFS=$'\t' read -r _ expected_account expected_uid _ _ _ _ _ _ _ _ expected_microphone expected_speech expected_accessibility expected_assets expected_input <<< "$profile_row"
mkdir -p "$evidence_root"

set +e
"$source_root/Scripts/oigo-native-qa-permission-profile-receipt.sh" \
    --profile "${value[profile]}" --source-root "$source_root" --source-sha "${value[app-source-sha]}" \
    --manifest-sha "$manifest_sha" --app "$app" --target "$target" \
    --ax-driver "$qa_root/oigo-qa-ax-driver" --key-driver "$qa_root/oigo-native-key-event-driver" \
    --evidence-root "$evidence_root" \
    --output "$evidence_root/permission-profile-receipt.txt" > "$evidence_root/permission-profile-helper.log" 2>&1
profile_status=$?
set -e

macos_version="$(sw_vers -productVersion)"
console_account="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
gui_session=false
if pgrep -qx WindowServer && [[ "$console_account" == "$(id -un)" ]]; then gui_session=true; fi
audio_facts="$evidence_root/audio-routes.txt"
system_profiler SPAudioDataType > "$audio_facts" 2>&1 || true
selected_input="$(awk '/Default Input Device: Yes/{found=1} found && /Input Source:/{sub(/^.*Input Source: /, ""); print; exit}' "$audio_facts")"
selected_output="$(awk '/Default Output Device: Yes/{found=1} found && /Output Source:/{sub(/^.*Output Source: /, ""); print; exit}' "$audio_facts")"
permission_output="$evidence_root/permission-state.txt"
"$qa_root/oigo-native-permission-preflight" > "$permission_output" 2>&1
microphone="$(sed -n 's/^MICROPHONE_CHECKPOINT=//p' "$permission_output")"
speech="$(sed -n 's/^SPEECH_CHECKPOINT=//p' "$permission_output")"
accessibility="$(sed -n 's/^AX_CHECKPOINT=//p' "$permission_output")"
input="$(sed -n 's/^INPUT_CHECKPOINT=//p' "$permission_output")"
assets=ready
[[ "$speech" == ready ]] || assets=missing
{
    print "PROFILE=${value[profile]}"
    print "OBSERVED_ACCOUNT=$(id -un)"
    print "OBSERVED_UID=$(id -u)"
    print "MACOS_VERSION=$macos_version"
    print "GUI_SESSION=$gui_session"
    print "SELECTED_INPUT=$selected_input"
    print "SELECTED_OUTPUT=$selected_output"
    print "MICROPHONE=$microphone"
    print "SPEECH=$speech"
    print "ACCESSIBILITY=$accessibility"
    print "ASSETS=$assets"
    print "INPUT=$input"
    sed -n 's/^PERMISSION_PROFILE_RECEIPT_SHA=/PERMISSION_PROFILE_RECEIPT_SHA=/p' "$evidence_root/permission-profile-receipt.txt" 2>/dev/null || true
} > "$evidence_root/preflight-facts.txt"

ready=true
[[ "$profile_status" == 0 && "$(id -un)" == "$expected_account" && "$(id -u)" == "$expected_uid" ]] || ready=false
[[ "$macos_version" == 26.* && "$gui_session" == true ]] || ready=false
[[ -n "$selected_output" ]] || ready=false
if [[ "$expected_input" == ready ]]; then [[ -n "$selected_input" ]] || ready=false; fi
[[ "$microphone" == "$expected_microphone" && "$speech" == "$expected_speech" && "$accessibility" == "$expected_accessibility" && "$assets" == "$expected_assets" && "$input" == "$expected_input" ]] || ready=false
if ! $ready; then
    print "INCONCLUSIVE profile-precondition" | tee "$evidence_root/preflight-result.txt"
    exit 2
fi
print "PREFLIGHT_READY profile=${value[profile]}" | tee "$evidence_root/preflight-result.txt"
