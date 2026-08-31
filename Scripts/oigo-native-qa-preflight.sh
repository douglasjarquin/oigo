#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

source_root="" app="" app_source_sha="" app_sha="" qa_root="" evidence_root="" frontmost_app="" target_field_id="" deny=""
while (( $# > 0 )); do
    [[ $# -ge 2 ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
    case "$1" in
        --source-root) source_root="$2" ;;
        --app) app="$2" ;;
        --app-source-sha) app_source_sha="$2" ;;
        --app-sha) app_sha="$2" ;;
        --qa-root) qa_root="$2" ;;
        --evidence-root) evidence_root="$2" ;;
        --frontmost-app) frontmost_app="$2" ;;
        --target-field-id) target_field_id="$2" ;;
        --deny) deny="$2" ;;
        *) print -u2 "ERROR unknown-argument"; exit 64 ;;
    esac
    shift 2
done
if [[ -z "$source_root" || -z "$app" || -z "$app_source_sha" || -z "$app_sha" || -z "$qa_root" || -z "$evidence_root" || -z "$frontmost_app" || -z "$target_field_id" ]]; then
    print -u2 "ERROR missing-argument"
    exit 64
fi
if [[ -n "$deny" && "$deny" != accessibility && "$deny" != window-server ]]; then
    print -u2 "ERROR invalid-failure-provider"
    exit 64
fi
if [[ ! -d "$app" ]]; then print -u2 "ERROR missing-bundle"; exit 1; fi
if [[ "${app:t}" != "Oigo.app" ]]; then print -u2 "ERROR wrong-bundle-name"; exit 1; fi
if [[ ! -d "$qa_root" || ! -f "$qa_root/run.json" ]]; then print -u2 "ERROR invalid-run-marker"; exit 1; fi
qa_root="$(cd "$qa_root" && pwd -P)"
source_root="$(cd "$source_root" && pwd -P)"
app="$(cd "$app" && pwd -P)"
frontmost_app="$(cd "$frontmost_app" 2>/dev/null && pwd -P || true)"
attempt_dir="$(jq -r .attempt_dir "$qa_root/run.json")"
attempt_dir="$(cd "$attempt_dir" && pwd -P)"
evidence_root="${evidence_root:A}"
if ! jq -e --arg qa_root "$qa_root" --arg attempt_dir "$attempt_dir" --arg repository "${qa_root:h:h}" '
    .qa_root == $qa_root and .attempt_dir == $attempt_dir and .repository == $repository and
    .reviewed_plan_sha == "4b7cf8d3e0e323b5b3d7e0f17467e5b99901682b81255ad5f06c33ad2e42a198" and
    .execution_base_sha == "a8315736e9b9ebb8c8e0a4bd6caa987eb67b2c37" and
    (.run_uuid | test("^[0-9a-fA-F-]{36}$"))
' "$qa_root/run.json" >/dev/null; then print -u2 "ERROR invalid-run-marker"; exit 1; fi
if [[ "$source_root" != "$qa_root/source-$app_source_sha" ]]; then print -u2 "ERROR source-sha-mismatch"; exit 1; fi
if [[ "$app" != "$qa_root"/* || "$frontmost_app" != "$qa_root"/* ]]; then print -u2 "ERROR outside-qa-root"; exit 1; fi
if [[ "$evidence_root" != "$attempt_dir"/* ]]; then print -u2 "ERROR outside-evidence-root"; exit 1; fi
if [[ "${HOME:A}" != "$qa_root/home" || "${CFFIXED_USER_HOME:A}" != "$qa_root/home" ]]; then print -u2 "ERROR nonisolated-home"; exit 1; fi
if [[ ! "$app_source_sha" =~ '^[0-9a-f]{40}$' || ! "$app_sha" =~ '^[0-9a-f]{64}$' ]]; then print -u2 "ERROR invalid-sha"; exit 1; fi
actual_sha="$("$source_root/Scripts/oigo-bundle-sha256.sh" "$app" | sed -n 's/^APP_BUNDLE_SHA=sha256://p')"
if [[ "$actual_sha" != "$app_sha" ]]; then print -u2 "ERROR app-sha-mismatch"; exit 1; fi
if [[ ! -d "$frontmost_app" ]]; then print -u2 "ERROR missing-target-bundle"; exit 1; fi
target_info="$frontmost_app/Contents/Info.plist"
target_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_info" 2>/dev/null || true)"
declared_field_id="$(/usr/libexec/PlistBuddy -c 'Print :OigoQATargetFieldIdentifier' "$target_info" 2>/dev/null || true)"
if [[ -z "$target_bundle_id" ]]; then print -u2 "ERROR missing-target-bundle-identifier"; exit 1; fi
if [[ "$declared_field_id" != "$target_field_id" ]]; then print -u2 "ERROR target-field-not-found"; exit 1; fi

cleanup() {
    pgrep -f "$frontmost_app/Contents/MacOS/OigoQATarget" | while read -r process_id; do
        kill "$process_id" 2>/dev/null || true
    done
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM
mkdir -p "$evidence_root" "$qa_root/session/task-1"
ax_binary="$qa_root/session/task-1/oigo-qa-ax-driver"
/usr/bin/xcrun swiftc "$source_root/Scripts/oigo-qa-ax-driver.swift" -framework AppKit -framework ApplicationServices -o "$ax_binary"
ax_output="$qa_root/session/task-1/preflight-ax.txt"
window_server="false"
ax_gate="inconclusive-window-server"
if [[ "$deny" == window-server ]]; then
    ax_gate="inconclusive-window-server-injected"
    print "INCONCLUSIVE window-server" > "$ax_output"
elif [[ "$deny" == accessibility ]]; then
    if pgrep -qx WindowServer; then window_server="true"; fi
    ax_gate="inconclusive-accessibility-injected"
    print "INCONCLUSIVE accessibility" > "$ax_output"
elif pgrep -qx WindowServer; then
    window_server="true"
    set +e
    "$ax_binary" --app "$frontmost_app" --field-id "$target_field_id" > "$ax_output" 2>&1
    ax_status=$?
    set -e
    if (( ax_status != 0 && ax_status != 2 )); then
        tail -1 "$ax_output" >&2
        exit 1
    fi
    ax_gate="ready"
    if (( ax_status == 2 )); then ax_gate="inconclusive-accessibility"; fi
else
    print "INCONCLUSIVE window-server" > "$ax_output"
fi
payload="$qa_root/session/task-1/preflight-payload.json"
xcode_version="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version | tr '\n' ';')"
jq -n --arg target_bundle_id "$target_bundle_id" --arg target_field_id "$target_field_id" --arg ax_gate "$ax_gate" --arg deny "$deny" --argjson window_server "$window_server" --arg xcode_version "$xcode_version" --arg macos_version "$(sw_vers -productVersion)" --arg architecture "$(uname -m)" --arg app_path "<qa-root>/${app#$qa_root/}" '{bundle:"validated",app_path:$app_path,target_bundle_id:$target_bundle_id,target_field_id:$target_field_id,window_server:$window_server,ax_gate:$ax_gate,failure_provider:(if $deny == "" then null else $deny end),xcode_version:$xcode_version,macos_version:$macos_version,architecture:$architecture,appearance:"system",home:"<qa-root>/home",cfix_home:"<qa-root>/home",screen_recording:"not-required-no-request",capture_policy:"oigo-owned-in-process-only"}' > "$payload"
"$source_root/Scripts/oigo-qa-write-evidence.sh" --run-marker "$qa_root/run.json" --output "$evidence_root/receipt.json" --verdict "PREFLIGHT_READY" --source-sha "$app_source_sha" --app-sha "$app_sha" --scenario preflight --payload-file "$payload"
print "PREFLIGHT_READY ax=$ax_gate frontmost=$target_bundle_id"
