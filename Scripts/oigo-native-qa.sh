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
    allowed_cases=(microphone-unavailable microphone-denied speech-unavailable input-unavailable assets-unavailable startup-release audio-start-failure stale-generation secure-field accessibility-denied window-server-unavailable)
    [[ " ${allowed_cases[*]} " == *" ${values[case]-} "* ]] || { print -u2 "ERROR unsupported-case"; exit 64; }
elif [[ "$scenario" == keyboard-release-lifecycle ]]; then
    allowed_cases=(release-before-ready release-during-recording interrupt-during-audio app-close-during-terminalization)
    [[ -z "${values[case]-}" || " ${allowed_cases[*]} " == *" ${values[case]} "* ]] || { print -u2 "ERROR unsupported-case"; exit 64; }
elif [[ -n "${values[case]-}" ]]; then
    print -u2 "ERROR unsupported-case"
    exit 64
fi

run_global_shortcut=false
if [[ "$scenario" == global-shortcut || ("$scenario" == all && "$run_global_shortcut" == true) ]]; then
    run_global_shortcut=true
elif [[ "$scenario" == all && -n "${values[frontmost-app]-}" ]]; then
    run_global_shortcut=true
fi
if [[ "$scenario" != keyboard-release-lifecycle && "$scenario" != failure && "$run_global_shortcut" == true ]]; then
    required_cross_app=(frontmost-app target-field-id configure-key-code configure-modifiers event-key-code event-modifiers)
    for key in $required_cross_app; do [[ -n "${values[$key]-}" ]] || { print -u2 "ERROR missing-argument"; exit 64; }; done
    for key in configure-key-code event-key-code; do
        [[ "${values[$key]}" =~ '^[0-9]+$' ]] && (( values[$key] <= 65535 )) || { print -u2 "ERROR invalid-key-code"; exit 64; }
    done
    for key in configure-modifiers event-modifiers; do
        [[ "${values[$key]}" =~ '^(command|shift|option|control|function)(,(command|shift|option|control|function))*$' ]] || { print -u2 "ERROR invalid-modifiers"; exit 64; }
    done
fi
if [[ "$scenario" == global-shortcut || ("$scenario" == all && "$run_global_shortcut" == true) ]]; then
    $relaunch || { print -u2 "ERROR relaunch-required"; exit 64; }
    [[ "${values[configure-key-code]}" == 0 && "${values[event-key-code]}" == 0 &&
       "${values[configure-modifiers]}" == command && "${values[event-modifiers]}" == command ]] || {
        print -u2 "ERROR unpinned-shortcut-fixture"
        exit 64
    }
    if [[ -n "${values[deny]-}" ]]; then
        [[ "${values[deny]}" == accessibility || "${values[deny]}" == window-server ]] || {
            print -u2 "ERROR invalid-failure-provider"
            exit 64
        }
        expected_case="${values[deny]}-denied"
        if [[ "${values[deny]}" == window-server ]]; then expected_case="window-server-unavailable"; fi
        [[ "${OIGO_QA_CASE-}" == "$expected_case" ]] || {
            print -u2 "ERROR invalid-failure-provider"
            exit 64
        }
    fi
fi

source_root="${values[source-root]:A}"
qa_root="${values[qa-root]:A}"
evidence_root="${values[evidence-root]:A}"
fixture_root="$qa_root/${fixtures[$scenario]}"
if [[ "$scenario" == failure && -n "${values[fixture-root]-}" ]]; then
    supplied_fixture_root="${values[fixture-root]:A}"
    [[ "$supplied_fixture_root" == "$fixture_root" || "$supplied_fixture_root" == "$fixture_root/${values[case]}" ]] || {
        print -u2 "ERROR fixture-root-mismatch"
        exit 1
    }
    fixture_root="$supplied_fixture_root"
else
    [[ -z "${values[fixture-root]-}" || "${values[fixture-root]:A}" == "$fixture_root" ]] || { print -u2 "ERROR fixture-root-mismatch"; exit 1; }
fi
attempt_dir="$(jq -r .attempt_dir "$qa_root/run.json")"
[[ "$evidence_root" == "$attempt_dir/${evidence_tasks[$scenario]}" || "$evidence_root" == "$attempt_dir/${evidence_tasks[$scenario]}"/* ]] || { print -u2 "ERROR evidence-root-mismatch"; exit 1; }
mkdir -p "$fixture_root" "$evidence_root" "$qa_root/session/native-qa"

source_root="${source_root:A}"
qa_root="${qa_root:A}"
app="${values[app]:A}"
[[ -d "$source_root" && "$source_root" == "$qa_root/source-${values[app-source-sha]}" ]] || { print -u2 "ERROR source-sha-mismatch"; exit 1; }
[[ -d "$app" && "${app:t}" == Oigo.app && "$app" == "$qa_root"/* ]] || { print -u2 "ERROR invalid-bundle"; exit 1; }
[[ "${values[app-source-sha]}" =~ '^[0-9a-f]{40}$' && "${values[app-sha]}" =~ '^[0-9a-f]{64}$' ]] || { print -u2 "ERROR invalid-sha"; exit 1; }
actual_sha="$("$source_root/Scripts/oigo-bundle-sha256.sh" "$app" | sed -n 's/^APP_BUNDLE_SHA=sha256://p')"
[[ "$actual_sha" == "${values[app-sha]}" ]] || { print -u2 "ERROR app-sha-mismatch"; exit 1; }

if [[ "$scenario" == failure ]]; then
    failure_payload="$qa_root/session/native-qa/failure-payload.json"
    jq -n --arg suite "${suites[$scenario]}" --arg fixture "${fixture_root#$qa_root/}" \
        --arg failure_case "${values[case]}" --arg provider "${values[deny]-}" \
        '{suite:$suite,fixture:$fixture,failure_case:$failure_case,failure_provider:(if $provider == "" then null else $provider end),outcome:"INCONCLUSIVE",category:$failure_case,native_pass:false,state_mutated:false,shared_system_mutated:false,physical_edges:[],checkpoint_execution:"not-run-by-injected-provider",recovery:"no-PASS-emitted"}' > "$failure_payload"
    "$source_root/Scripts/oigo-qa-write-evidence.sh" --run-marker "$qa_root/run.json" \
        --output "$evidence_root/native-qa-receipt.json" --verdict INCONCLUSIVE \
        --source-sha "${values[app-source-sha]}" --app-sha "${values[app-sha]}" \
        --scenario "$scenario" --payload-file "$failure_payload"
    print "INCONCLUSIVE ${values[case]}"
    exit 0
fi

if [[ "$scenario" == all && "$run_global_shortcut" == false ]]; then
    aggregate_payload="$qa_root/session/native-qa/aggregate-payload.json"
    jq -n --arg suite "${suites[$scenario]}" --arg fixture "$fixture_root" \
        '{suite:$suite,fixture:$fixture,category:"native-target-not-supplied",outcome:"INCONCLUSIVE",blocking_rows:["H82-01","H82-02","H82-09"],native_pass:false,state_mutated:false,shared_system_mutated:false,aggregate:"bounded-acceptance-only"}' > "$aggregate_payload"
    "$source_root/Scripts/oigo-qa-write-evidence.sh" --run-marker "$qa_root/run.json" \
        --output "$evidence_root/native-qa-receipt.json" --verdict INCONCLUSIVE \
        --source-sha "${values[app-source-sha]}" --app-sha "${values[app-sha]}" \
        --scenario "$scenario" --payload-file "$aggregate_payload"
    print "INCONCLUSIVE native-target-not-supplied"
    exit 0
fi

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

if [[ "$scenario" == global-shortcut ]]; then
    app_pid=""
    cleanup_global_shortcut() {
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
    trap cleanup_global_shortcut EXIT
    trap 'cleanup_global_shortcut; exit 130' INT TERM

    preflight_arguments=(
        --source-root "$source_root" --app "${values[app]}"
        --app-source-sha "${values[app-source-sha]}" --app-sha "${values[app-sha]}"
        --qa-root "$qa_root" --evidence-root "$evidence_root/preflight-driver"
        --frontmost-app "${values[frontmost-app]}" --target-field-id "${values[target-field-id]}"
    )
    if [[ -n "${values[deny]-}" ]]; then preflight_arguments+=(--deny "${values[deny]}"); fi
    "$source_root/Scripts/oigo-native-qa-preflight.sh" $preflight_arguments

    key_binary="$qa_root/session/native-qa/oigo-native-key-event-driver"
    /usr/bin/xcrun swiftc "$source_root/Scripts/oigo-native-key-event-driver.swift" \
        -framework ApplicationServices -o "$key_binary"
    permission_binary="$qa_root/session/native-qa/oigo-native-permission-preflight"
    /usr/bin/xcrun swiftc "$source_root/Scripts/oigo-native-permission-preflight.swift" \
        -framework AVFoundation -framework ApplicationServices -framework CoreGraphics \
        -framework Speech -o "$permission_binary"
    permission_output="$("$permission_binary")"
    set +e
    event_access_output="$("$key_binary" --check-only 2>&1)"
    event_access_status=$?
    set -e

    typeset -a unavailable
    unavailable=()
    if [[ -n "${values[deny]-}" ]]; then
        unavailable+=("${values[deny]}")
    else
        if ! pgrep -qx WindowServer; then unavailable+=(window-server); fi
        if rg -q 'inconclusive-accessibility' "$evidence_root/preflight-driver/receipt.json"; then
            unavailable+=(accessibility)
        fi
        if rg -q 'inconclusive-target-field-unavailable' "$evidence_root/preflight-driver/receipt.json"; then
            unavailable+=(target-field-unavailable)
        fi
        if (( event_access_status == 2 )); then unavailable+=(coregraphics-post-event); fi
        if [[ "$permission_output" != *"MICROPHONE_CHECKPOINT=granted"* ]]; then unavailable+=(microphone); fi
        if [[ "$permission_output" != *"SPEECH_CHECKPOINT=ready"* ]]; then unavailable+=(speech); fi
        if [[ "$permission_output" != *"INPUT_CHECKPOINT=ready"* ]]; then unavailable+=(input); fi
        if [[ "$permission_output" != *"HARDWARE_CHECKPOINT=ready"* ]]; then unavailable+=(hardware); fi
    fi
    categories_json="$(printf '%s\n' $unavailable | jq -R -s 'split("\n") | map(select(length > 0)) | unique')"
    h82_01_categories="$(jq '[.[] | select(. == "window-server" or . == "accessibility" or . == "coregraphics-post-event" or . == "target-field-unavailable")]' <<< "$categories_json")"
    h82_02_categories="$categories_json"
    h82_09_categories="$(jq '[.[] | select(. == "window-server" or . == "accessibility" or . == "target-field-unavailable")]' <<< "$categories_json")"

    write_h82_receipt() {
        local row="$1" row_verdict="$2" row_categories_json="$3" mechanisms_json="$4" result="$5"
        local row_payload="$qa_root/session/native-qa/${row}-payload.json"
        jq -n --arg row "$row" --arg result "$result" \
            --arg artifact "sha256:${values[app-sha]}" --argjson categories "$row_categories_json" \
            --argjson mechanisms "$mechanisms_json" \
            '{row:$row,result:$result,categories:$categories,mechanisms:$mechanisms,app_bundle_artifact:$artifact,native_pass:($result == "NATIVE PASS")}' > "$row_payload"
        "$source_root/Scripts/oigo-qa-write-evidence.sh" --run-marker "$qa_root/run.json" \
            --output "$evidence_root/${row:l}.json" --verdict "$row_verdict" \
            --source-sha "${values[app-source-sha]}" --app-sha "${values[app-sha]}" \
            --scenario "$scenario" --payload-file "$row_payload"
    }

    if (( ${#unavailable[@]} > 0 )); then
        write_h82_receipt H82-01 INCONCLUSIVE "$h82_01_categories" \
            '["window-server","accessibility","coregraphics-post-event","carbon-hot-key","frontmost-identity"]' INCONCLUSIVE
        write_h82_receipt H82-02 INCONCLUSIVE "$h82_02_categories" \
            '["window-server","accessibility","coregraphics-post-event","microphone","speech","input","hardware","terminalization"]' INCONCLUSIVE
        write_h82_receipt H82-09 INCONCLUSIVE "$h82_09_categories" \
            '["window-server","accessibility","frontmost-identity","focused-field"]' INCONCLUSIVE
        payload="$qa_root/session/native-qa/payload.json"
        jq -n --arg suite "${suites[$scenario]}" --arg fixture "${fixtures[$scenario]}" \
            --arg event_access "$event_access_output" --arg permission_checkpoints "$permission_output" \
            --arg provider "${values[deny]-}" --argjson categories "$categories_json" \
            '{suite:$suite,fixture:$fixture,categories:$categories,failure_provider:(if $provider == "" then null else $provider end),event_access:$event_access,permission_checkpoints:$permission_checkpoints,input_monitoring:"not-required-no-event-tap",screen_recording:"not-required-oigo-owned-capture",state_mutated:false,native_pass:false}' > "$payload"
        "$source_root/Scripts/oigo-qa-write-evidence.sh" --run-marker "$qa_root/run.json" \
            --output "$evidence_root/native-qa-receipt.json" --verdict INCONCLUSIVE \
            --source-sha "${values[app-source-sha]}" --app-sha "${values[app-sha]}" \
            --scenario "$scenario" --payload-file "$payload"
        print "INCONCLUSIVE ${unavailable[*]}"
        exit 0
    fi

    checkpoint_file="$qa_root/session/native-qa/oigo-checkpoints.jsonl"
    frontmost_log="$qa_root/session/native-qa/frontmost-checkpoints.log"
    edge_log="$qa_root/session/native-qa/physical-edges.log"
    settings_log="$qa_root/session/native-qa/settings-values.log"
    app_log="$qa_root/session/native-qa/oigo.log"
    : > "$checkpoint_file"
    : > "$frontmost_log"
    : > "$edge_log"
    : > "$settings_log"
    : > "$app_log"

    checkpoint_count() {
        local checkpoint="$1"
        jq -s --arg checkpoint "$checkpoint" \
            '[.[] | select(.checkpoint == $checkpoint)] | length' "$checkpoint_file" 2>/dev/null || print 0
    }

    wait_checkpoint() {
        local checkpoint="$1" expected_count="$2" timeout_seconds="$3"
        local deadline=$(( SECONDS + timeout_seconds ))
        while (( SECONDS < deadline )); do
            if (( $(checkpoint_count "$checkpoint") >= expected_count )); then return 0; fi
            /bin/sleep 0.1
        done
        print -u2 "ERROR checkpoint-timeout:$checkpoint"
        return 1
    }

    app_executable="${values[app]}/Contents/MacOS/Oigo"
    ax_binary="$qa_root/session/task-1/oigo-qa-ax-driver"
    target_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "${values[frontmost-app]}/Contents/Info.plist")"
    "$ax_binary" --app "${values[frontmost-app]}" --field-id "${values[target-field-id]}" \
        --focus --frontmost-checkpoint before-save >> "$frontmost_log"
    HOME="$qa_root/home" CFFIXED_USER_HOME="$qa_root/home" CFPREFERENCES_AVOID_DAEMON=1 \
        OIGO_QA_MODE=1 OIGO_QA_SCENARIO="$scenario" OIGO_QA_CASE=seed-onboarding \
        OIGO_QA_FIXTURE_ROOT="$fixture_root" OIGO_QA_RUN_MARKER="$qa_root/run.json" \
        "$app_executable" >> "$app_log" 2>&1 &
    app_pid=$!
    wait_checkpoint app-launch 1 12
    "$ax_binary" --app "${values[app]}" --control-id oigo.settings.shortcut-recorder --press-control
    "$key_binary" --key-code "${values[configure-key-code]}" \
        --modifiers "${values[configure-modifiers]}" --edge both >> "$edge_log"
    wait_checkpoint settings-save 1 8
    "$ax_binary" --app "${values[app]}" --control-id oigo.settings.shortcut-recorder \
        --read-value >> "$settings_log"
    rg -q 'value=⌘A$' "$settings_log" || { print -u2 "ERROR settings-save-readback"; exit 1; }

    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    app_pid=""
    HOME="$qa_root/home" CFFIXED_USER_HOME="$qa_root/home" CFPREFERENCES_AVOID_DAEMON=1 \
        OIGO_QA_MODE=1 OIGO_QA_SCENARIO="$scenario" \
        OIGO_QA_FIXTURE_ROOT="$fixture_root" OIGO_QA_RUN_MARKER="$qa_root/run.json" \
        "$app_executable" >> "$app_log" 2>&1 &
    app_pid=$!
    wait_checkpoint app-launch 2 12
    "$ax_binary" --app "${values[app]}" --control-id oigo.settings.shortcut-recorder \
        --read-value >> "$settings_log"
    (( $(rg -c 'value=⌘A$' "$settings_log") == 2 )) || {
        print -u2 "ERROR settings-relaunch-readback"
        exit 1
    }
    "$ax_binary" --app "${values[frontmost-app]}" --field-id "${values[target-field-id]}" \
        --focus --frontmost-checkpoint after-relaunch >> "$frontmost_log"

    "$key_binary" --key-code "${values[event-key-code]}" \
        --modifiers "${values[event-modifiers]}" --edge down >> "$edge_log"
    wait_checkpoint key-down-received 1 8
    "$ax_binary" --frontmost-checkpoint key-down >> "$frontmost_log"
    wait_checkpoint recording 1 45
    "$ax_binary" --frontmost-checkpoint recording >> "$frontmost_log"
    "$key_binary" --key-code "${values[event-key-code]}" \
        --modifiers "${values[event-modifiers]}" --edge up >> "$edge_log"
    wait_checkpoint key-up-received 1 8
    "$ax_binary" --frontmost-checkpoint key-up >> "$frontmost_log"
    wait_checkpoint terminalization 1 90
    wait_checkpoint durable-raw-persistence 1 5
    wait_checkpoint dispatch-acknowledgement 1 5
    "$ax_binary" --frontmost-checkpoint terminal >> "$frontmost_log"
    "$ax_binary" --app "${values[frontmost-app]}" --field-id "${values[target-field-id]}" \
        --no-activate --require-focused --frontmost-checkpoint focus-restoration >> "$frontmost_log"

    jq -s -e '
        ([.[] | select(.checkpoint == "app-launch")] | length) == 2 and
        ([.[] | select(.checkpoint == "settings-save" and .key_code == 0 and .modifiers == 256)] | length) == 1 and
        ([.[] | select(.checkpoint == "durable-session")] | length) == 1 and
        any(.[]; .checkpoint == "durable-raw-persistence" and .nonempty == true) and
        any(.[]; .checkpoint == "dispatch-acknowledgement" and .acknowledged == true) and
        ([.[] | select(.checkpoint == "terminalization")] | length) == 1
    ' "$checkpoint_file" >/dev/null || { print -u2 "ERROR oigo-receipt-incomplete"; exit 1; }
    for checkpoint in before-save after-relaunch key-down recording key-up terminal focus-restoration; do
        rg -q "name=$checkpoint bundle=$target_bundle_id" "$frontmost_log" || {
            print -u2 "ERROR frontmost-checkpoint:$checkpoint"
            exit 1
        }
    done
    rg -q 'AX_FOCUS_CHECKPOINT .* focused=true' "$frontmost_log" || {
        print -u2 "ERROR focus-not-restored"
        exit 1
    }

    capture="$qa_root/session/captures/$scenario/settings.png"
    capture_state="not-produced"
    if [[ -s "$capture" ]]; then
        capture_state="oigo-owned-in-process-sha256:$(shasum -a 256 "$capture" | awk '{print $1}')"
    fi
    checkpoint_summary="$qa_root/session/native-qa/checkpoint-summary.json"
    jq -s 'group_by(.checkpoint) | map({key:.[0].checkpoint,value:length}) | from_entries' \
        "$checkpoint_file" > "$checkpoint_summary"
    write_h82_receipt H82-01 PASS '[]' \
        '["window-server","accessibility","coregraphics-post-event","carbon-hot-key","frontmost-identity"]' 'NATIVE PASS'
    write_h82_receipt H82-02 PASS '[]' \
        '["window-server","accessibility","coregraphics-post-event","microphone","speech","input","hardware","terminalization"]' 'NATIVE PASS'
    write_h82_receipt H82-09 PASS '[]' \
        '["window-server","accessibility","frontmost-identity","focused-field"]' 'NATIVE PASS'
    payload="$qa_root/session/native-qa/payload.json"
    jq -n --arg suite "${suites[$scenario]}" --arg fixture "${fixtures[$scenario]}" \
        --arg target_bundle "$target_bundle_id" --arg capture "$capture_state" \
        --arg event_access "$event_access_output" --arg permission_checkpoints "$permission_output" \
        --slurpfile checkpoints "$checkpoint_summary" \
        '{suite:$suite,fixture:$fixture,target_bundle:$target_bundle,configured_shortcut:{key_code:0,modifiers:"command",read_back_after_relaunch:true},physical_edges:["down","up"],checkpoints:$checkpoints[0],durable_raw_nonempty:true,dispatch_acknowledged:true,clipboard_verified:false,focus_restored:true,event_access:$event_access,permission_checkpoints:$permission_checkpoints,capture:$capture,input_monitoring:"not-required-no-event-tap",screen_recording:"not-required-oigo-owned-capture",native_pass:true}' > "$payload"
    "$source_root/Scripts/oigo-qa-write-evidence.sh" --run-marker "$qa_root/run.json" \
        --output "$evidence_root/native-qa-receipt.json" --verdict PASS \
        --source-sha "${values[app-source-sha]}" --app-sha "${values[app-sha]}" \
        --scenario "$scenario" --payload-file "$payload"
    print "PASS global-shortcut H82-01 H82-02 H82-09"
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
/usr/bin/xcrun swiftc "$source_root/Scripts/oigo-native-permission-preflight.swift" \
    -framework AVFoundation -framework ApplicationServices -framework CoreGraphics \
    -framework Speech -o "$permission_binary"
permission_output="$($permission_binary)"
set +e
event_access_output="$($key_binary --check-only 2>&1)"
event_access_status=$?
set -e

verdict="BASELINE_OBSERVED"
category="none"
if ! pgrep -qx WindowServer; then verdict="INCONCLUSIVE"; category="window-server"; fi
if (( event_access_status == 2 )); then verdict="INCONCLUSIVE"; category="coregraphics-post-event"; fi
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
