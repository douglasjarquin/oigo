#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

typeset -A values
relaunch=false
while (( $# > 0 )); do
    case "$1" in
        --relaunch)
            $relaunch && { print -u2 "ERROR duplicate-argument"; exit 64; }
            relaunch=true
            shift
            ;;
        --source-root|--app-source-sha|--app|--app-sha|--qa-root|--evidence-root|--scenario|--case|--fixture-root|--frontmost-app|--target-field-id|--configure-key-code|--configure-modifiers|--event-key-code|--event-modifiers|--deny)
            [[ $# -ge 2 && "$2" != --* ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
            key="${1#--}"
            [[ -z "${values[$key]-}" ]] || { print -u2 "ERROR duplicate-argument"; exit 64; }
            values[$key]="$2"
            shift 2
            ;;
        *) print -u2 "ERROR unknown-argument"; exit 64 ;;
    esac
done
required=(source-root app-source-sha app app-sha qa-root evidence-root scenario)
for key in $required; do [[ -n "${values[$key]-}" ]] || { print -u2 "ERROR missing-argument"; exit 64; }; done

typeset -A suites fixtures evidence_tasks
suites=(global-shortcut-baseline com.oigo.qa.task01 keyboard-release-lifecycle com.oigo.qa.task16 global-shortcut com.oigo.qa.task17 failure com.oigo.qa.task33 all com.oigo.qa.task33)
fixtures=(global-shortcut-baseline fixtures/native/task-01 keyboard-release-lifecycle fixtures/native/task-16 global-shortcut fixtures/native/task-17 failure fixtures/native/task-33/failures all fixtures/native/task-33)
evidence_tasks=(global-shortcut-baseline task-1 keyboard-release-lifecycle task-16 global-shortcut task-17 failure task-33 all task-33)
scenario="${values[scenario]}"
[[ -n "${suites[$scenario]-}" ]] || { print -u2 "ERROR unsupported-scenario"; exit 64; }
if [[ "$scenario" == failure ]]; then
    allowed_cases=(microphone-denied speech-unavailable input-unavailable assets-unavailable audio-start-failure accessibility-denied window-server-unavailable)
    [[ " ${allowed_cases[*]} " == *" ${values[case]-} "* ]] || { print -u2 "ERROR unsupported-case"; exit 64; }
elif [[ "$scenario" == keyboard-release-lifecycle ]]; then
    allowed_cases=(release-before-ready release-during-recording interrupt-during-audio app-close-during-terminalization)
    [[ -z "${values[case]-}" || " ${allowed_cases[*]} " == *" ${values[case]} "* ]] || { print -u2 "ERROR unsupported-case"; exit 64; }
elif [[ -n "${values[case]-}" ]]; then
    print -u2 "ERROR unsupported-case"
    exit 64
fi

if [[ "$scenario" != keyboard-release-lifecycle ]]; then
    required_cross_app=(frontmost-app target-field-id configure-key-code configure-modifiers event-key-code event-modifiers)
    for key in $required_cross_app; do [[ -n "${values[$key]-}" ]] || { print -u2 "ERROR missing-argument"; exit 64; }; done
    for key in configure-key-code event-key-code; do
        [[ "${values[$key]}" =~ '^[0-9]+$' ]] && (( values[$key] <= 65535 )) || { print -u2 "ERROR invalid-key-code"; exit 64; }
    done
    for key in configure-modifiers event-modifiers; do
        [[ "${values[$key]}" =~ '^(command|shift|option|control|function)(,(command|shift|option|control|function))*$' ]] || { print -u2 "ERROR invalid-modifiers"; exit 64; }
    done
fi

source_root="${values[source-root]:A}"
qa_root="${values[qa-root]:A}"
evidence_root="${values[evidence-root]:A}"
fixture_root="$qa_root/${fixtures[$scenario]}"
[[ -z "${values[fixture-root]-}" || "${values[fixture-root]:A}" == "$fixture_root" ]] || { print -u2 "ERROR fixture-root-mismatch"; exit 1; }
attempt_dir="$(jq -r .attempt_dir "$qa_root/run.json")"
[[ "$evidence_root" == "$attempt_dir/${evidence_tasks[$scenario]}" || "$evidence_root" == "$attempt_dir/${evidence_tasks[$scenario]}"/* ]] || { print -u2 "ERROR evidence-root-mismatch"; exit 1; }
mkdir -p "$fixture_root" "$evidence_root" "$qa_root/session/native-qa"

if [[ "$scenario" == keyboard-release-lifecycle ]]; then
    app="${values[app]:A}"
    [[ -d "$source_root" && "$source_root" == "$qa_root/source-${values[app-source-sha]}" ]] || { print -u2 "ERROR source-sha-mismatch"; exit 1; }
    [[ -d "$app" && "${app:t}" == Oigo.app && "$app" == "$qa_root"/* ]] || { print -u2 "ERROR invalid-bundle"; exit 1; }
    [[ "${values[app-source-sha]}" =~ '^[0-9a-f]{40}$' && "${values[app-sha]}" =~ '^[0-9a-f]{64}$' ]] || { print -u2 "ERROR invalid-sha"; exit 1; }
    actual_sha="$("$source_root/Scripts/oigo-bundle-sha256.sh" "$app" | sed -n 's/^APP_BUNDLE_SHA=sha256://p')"
    [[ "$actual_sha" == "${values[app-sha]}" ]] || { print -u2 "ERROR app-sha-mismatch"; exit 1; }
    mode="${values[case]-all}"
    lifecycle_receipt="$evidence_root/lifecycle-checkpoints.json"
    HOME="$qa_root/home" CFFIXED_USER_HOME="$qa_root/home" CFPREFERENCES_AVOID_DAEMON=1 \
        OIGO_QA_MODE=1 "$app/Contents/MacOS/Oigo" \
        --task-16-keyboard-release-probe "$mode" "${suites[$scenario]}" "$lifecycle_receipt"
    jq -e --arg mode "$mode" '
        .ownerIdentity == "oigo-app-delegate-keyboard-release-lifecycle" and
        .defaultsCleaned == true and
        (.rows | length == (if $mode == "all" then 4 else 1 end)) and
        all(.rows[];
            .checkpoints[0] == "preparation" and
            .checkpoints[-2:] == ["terminal", "cleanup"] and
            .terminalizationCount == 1 and
            .appResourceCount == 0 and .coordinatorResourceCount == 0 and
            .hudResourceCount == 0 and .timerResourceCount == 0 and
            (if .caseName == "release-before-ready" then
                .terminalState == "cancelled" and .durableState == "cancelled" and
                .durableRawBytes == 0 and .transcriptionCancelCount == 1 and .insertionCount == 0
             elif .caseName == "release-during-recording" then
                .terminalState == "complete" and .durableState == "completed" and
                .durableRawBytes > 0 and .captureStopCount == 1 and
                .transcriptionFinishCount == 1 and .insertionCount == 1
             else
                .terminalState == "interrupted" and .durableState == "interrupted" and
                .durableRawBytes > 0 and .transcriptionCancelCount == 1 and .insertionCount == 0
             end)
        )
    ' "$lifecycle_receipt" >/dev/null || { print -u2 "ERROR lifecycle-checkpoint-failed"; exit 1; }
    payload="$qa_root/session/native-qa/keyboard-release-payload.json"
    jq --arg mode "$mode" '{suite:"com.oigo.qa.task16",mode:$mode,provider:"synthetic-audio-and-speech",checkpoints:.rows,cleanup:"all-resource-counts-zero",native_pass:true}' "$lifecycle_receipt" > "$payload"
    "$source_root/Scripts/oigo-qa-write-evidence.sh" \
        --run-marker "$qa_root/run.json" --output "$evidence_root/native-qa-receipt.json" \
        --verdict PASS --source-sha "${values[app-source-sha]}" --app-sha "${values[app-sha]}" \
        --scenario "$scenario" --payload-file "$payload"
    print "PASS keyboard-release-lifecycle mode=$mode"
    exit 0
fi

app_pid=""
cleanup() {
    if [[ -n "$app_pid" ]]; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    pgrep -f "${values[app]}/Contents/MacOS/Oigo" | while read -r process_id; do
        kill "$process_id" 2>/dev/null || true
    done
    pgrep -f "${values[frontmost-app]}/Contents/MacOS/OigoQATarget" | while read -r process_id; do
        kill "$process_id" 2>/dev/null || true
    done
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

"$source_root/Scripts/oigo-native-qa-preflight.sh" \
    --source-root "$source_root" --app "${values[app]}" --app-source-sha "${values[app-source-sha]}" \
    --app-sha "${values[app-sha]}" --qa-root "$qa_root" --evidence-root "$evidence_root/preflight-driver" \
    --frontmost-app "${values[frontmost-app]}" --target-field-id "${values[target-field-id]}"

liveness_output="$qa_root/session/native-qa/liveness.txt"
HOME="$qa_root/home" CFFIXED_USER_HOME="$qa_root/home" \
    OIGO_QA_MODE=1 OIGO_QA_SCENARIO="$scenario" \
    OIGO_QA_FIXTURE_ROOT="$fixture_root" OIGO_QA_RUN_MARKER="$qa_root/run.json" \
    CFPREFERENCES_AVOID_DAEMON=1 \
    "$source_root/Scripts/bounded-oigo-launch.sh" "${values[app]}" > "$liveness_output" 2>&1
key_binary="$qa_root/session/native-qa/oigo-native-key-event-driver"
/usr/bin/xcrun swiftc "$source_root/Scripts/oigo-native-key-event-driver.swift" -framework ApplicationServices -o "$key_binary"
permission_binary="$qa_root/session/native-qa/oigo-native-permission-preflight"
/usr/bin/xcrun swiftc "$source_root/Scripts/oigo-native-permission-preflight.swift" -framework AVFAudio -framework ApplicationServices -framework CoreGraphics -o "$permission_binary"
permission_output="$($permission_binary)"
set +e
event_access_output="$($key_binary --check-only 2>&1)"
event_access_status=$?
set -e

verdict="BASELINE_OBSERVED"
category="none"
if ! pgrep -qx WindowServer; then verdict="INCONCLUSIVE"; category="window-server"; fi
if (( event_access_status == 2 )); then verdict="INCONCLUSIVE"; category="input-monitoring"; fi
if rg -q 'inconclusive-accessibility' "$evidence_root/preflight-driver/receipt.json"; then verdict="INCONCLUSIVE"; category="accessibility"; fi
if [[ "$permission_output" != *"MICROPHONE_CHECKPOINT=granted"* ]]; then verdict="INCONCLUSIVE"; category="microphone"; fi
if [[ -n "${values[deny]-}" ]]; then verdict="INCONCLUSIVE"; category="${values[deny]}"; fi
if [[ "$scenario" == failure ]]; then verdict="INCONCLUSIVE"; category="${values[case]}"; fi

capture_state="not-produced"
if [[ "$verdict" == "BASELINE_OBSERVED" ]]; then
    app_executable="${values[app]}/Contents/MacOS/Oigo"
    app_log="$qa_root/session/native-qa/oigo.log"
    qa_case="${values[case]-seed-onboarding}"
    OIGO_QA_MODE=1 OIGO_QA_SCENARIO="$scenario" OIGO_QA_CASE="$qa_case" \
        OIGO_QA_FIXTURE_ROOT="$fixture_root" OIGO_QA_RUN_MARKER="$qa_root/run.json" \
        "$app_executable" > "$app_log" 2>&1 &
    app_pid=$!
    ax_binary="$qa_root/session/task-1/oigo-qa-ax-driver"
    "$ax_binary" --app "${values[app]}" --control-id oigo.settings.shortcut-recorder --press-control
    "$key_binary" --key-code "${values[configure-key-code]}" --modifiers "${values[configure-modifiers]}" --edge both
    if $relaunch; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
        OIGO_QA_MODE=1 OIGO_QA_SCENARIO="$scenario" OIGO_QA_CASE="$qa_case" \
            OIGO_QA_FIXTURE_ROOT="$fixture_root" OIGO_QA_RUN_MARKER="$qa_root/run.json" \
            "$app_executable" > "$app_log" 2>&1 &
        app_pid=$!
    fi
    "$ax_binary" --app "${values[frontmost-app]}" --field-id "${values[target-field-id]}"
    "$key_binary" --key-code "${values[event-key-code]}" --modifiers "${values[event-modifiers]}" --edge down
    "$key_binary" --key-code "${values[event-key-code]}" --modifiers "${values[event-modifiers]}" --edge up
    capture="$qa_root/session/captures/$scenario/settings.png"
    if [[ -s "$capture" ]]; then capture_state="oigo-owned-in-process-sha256:$(shasum -a 256 "$capture" | awk '{print $1}')"; fi
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    app_pid=""
fi

payload="$qa_root/session/native-qa/payload.json"
jq -n --arg suite "${suites[$scenario]}" --arg fixture "${fixtures[$scenario]}" --arg category "$category" --arg event_access "$event_access_output" --arg permission_checkpoints "$permission_output" --arg capture "$capture_state" --arg frontmost_bundle "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${values[frontmost-app]}/Contents/Info.plist")" '{suite:$suite,fixture:$fixture,category:$category,ax_checkpoint:"recorded-by-preflight",frontmost_checkpoint:$frontmost_bundle,event_access:$event_access,permission_checkpoints:$permission_checkpoints,capture:$capture,screen_recording:"preflight-only-no-request",native_pass:false}' > "$payload"
"$source_root/Scripts/oigo-qa-write-evidence.sh" --run-marker "$qa_root/run.json" --output "$evidence_root/native-qa-receipt.json" --verdict "$verdict" --source-sha "${values[app-source-sha]}" --app-sha "${values[app-sha]}" --scenario "$scenario" --payload-file "$payload"
if [[ "$verdict" == "BASELINE_OBSERVED" ]]; then print "BASELINE_OBSERVED"; else print "INCONCLUSIVE $category"; fi
