#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

typeset -A value seen
relaunch=false
while (( $# > 0 )); do
    case "$1" in
        --relaunch)
            [[ "$relaunch" == false ]] || { print -u2 "ERROR duplicate-argument"; exit 64; }
            relaunch=true
            shift
            ;;
        --profile|--source-root|--app-source-sha|--app|--app-sha|--qa-root|--evidence-root|--scenario|--frontmost-app|--target-field-id|--event-key-code|--event-modifiers|--jsonl-output|--result-output)
            [[ $# -ge 2 && "$2" != --* ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
            key="$(print -r -- "$1" | sed 's/^--//')"
            [[ -z "${seen[$key]-}" ]] || { print -u2 "ERROR duplicate-argument"; exit 64; }
            seen[$key]=1
            value[$key]="$2"
            shift 2
            ;;
        *) print -u2 "ERROR unknown-argument"; exit 64 ;;
    esac
done

required=(profile source-root app-source-sha app app-sha qa-root evidence-root scenario frontmost-app target-field-id event-key-code event-modifiers)
for key in $required; do
    [[ -n "${value[$key]-}" ]] || { print -u2 "ERROR missing-argument"; exit 64; }
done
[[ "$relaunch" == true ]] || { print -u2 "ERROR relaunch-required"; exit 64; }

scenario="$value[scenario]"
case "$scenario" in
    public-dictation|changed-target|secure-field|denied-microphone|denied-accessibility|missing-speech-assets|unavailable-input) ;;
    *) print -u2 "ERROR unsupported-scenario"; exit 64 ;;
esac
[[ "$value[app-source-sha]" =~ '^[0-9a-f]{40}$' ]] || { print -u2 "ERROR invalid-source-sha"; exit 64; }
[[ "$value[app-sha]" =~ '^sha256:[0-9a-f]{64}$' ]] || { print -u2 "ERROR invalid-app-sha"; exit 64; }
[[ "$value[event-key-code]" =~ '^[0-9]+$' && $value[event-key-code] -le 65535 ]] || { print -u2 "ERROR invalid-key-code"; exit 64; }
[[ "$value[event-modifiers]" =~ '^(command|shift|option|control|function)(,(command|shift|option|control|function))*$' ]] || { print -u2 "ERROR invalid-modifiers"; exit 64; }

source_root_arg="$value[source-root]"
app_arg="$value[app]"
qa_root_arg="$value[qa-root]"
evidence_root_arg="$value[evidence-root]"
target_arg="$value[frontmost-app]"
source_root="$(cd "$source_root_arg" && pwd -P)"
app="$(cd "$app_arg" && pwd -P)"
qa_root="$(cd "$qa_root_arg" && pwd -P)"
evidence_parent_arg="$(dirname "$evidence_root_arg")"
[[ -d "$evidence_parent_arg" ]] || { print -u2 "ERROR missing-evidence-parent"; exit 1; }
evidence_root="$(cd "$evidence_parent_arg" && pwd -P)/$(basename "$evidence_root_arg")"
target="$(cd "$target_arg" && pwd -P)"
app_digest="$(print -r -- "$value[app-sha]" | sed 's/^sha256://')"
[[ -d "$source_root" && -f "$source_root/Package.swift" ]] || { print -u2 "ERROR invalid-source-root"; exit 1; }
[[ "$source_root" == "$qa_root/source-$value[app-source-sha]" ]] || { print -u2 "ERROR source-sha-mismatch"; exit 1; }
[[ "$evidence_root" == "$qa_root/evidence" || "$evidence_root" == "$qa_root/evidence"/* ]] || {
    print -u2 "ERROR evidence-root-outside-qa-root"
    exit 1
}
mkdir -p "$evidence_root"
[[ -d "$app" && "$(basename "$app")" == Oigo.app && "$app" == "$qa_root"/* ]] || { print -u2 "ERROR invalid-app-bundle"; exit 1; }
[[ -d "$target" && "$(basename "$target")" == OigoQATarget.app && "$target" == "$qa_root"/* ]] || { print -u2 "ERROR invalid-target-bundle"; exit 1; }
[[ -x "$app/Contents/MacOS/Oigo" ]] || { print -u2 "ERROR missing-app-executable"; exit 1; }
[[ -x "$qa_root/oigo-qa-ax-driver" && -x "$qa_root/oigo-native-key-event-driver" ]] || { print -u2 "ERROR missing-external-driver"; exit 1; }
actual_app_digest="$("$source_root/Scripts/oigo-bundle-sha256.sh" "$app" | sed -n 's/^APP_BUNDLE_SHA=sha256://p')"
[[ "$actual_app_digest" == "$app_digest" ]] || { print -u2 "ERROR app-sha-mismatch"; exit 1; }

runner_marker="$qa_root/native-qa-marker.json"
repository_root="$(jq -r '.repository // empty' "$runner_marker" 2>/dev/null || true)"
[[ -n "$repository_root" && -d "$repository_root" ]] || { print -u2 "ERROR missing-repository-marker"; exit 1; }
repository_root="$(cd "$repository_root" && pwd -P)"
atomic_write() {
    local destination="$1"
    local temporary
    temporary="$(mktemp "${destination:h}/.oigo-runner.XXXXXX")"
    cat > "$temporary"
    /usr/bin/ruby -e 'File.open(ARGV.fetch(0), "r") { |file| file.fsync }' "$temporary"
    mv "$temporary" "$destination"
}
atomic_write "$runner_marker" <<EOF
$(jq -n --arg attempt_dir "$evidence_root" --arg qa_root "$qa_root" --arg repository "$repository_root" --arg source_sha "$value[app-source-sha]" --arg app_sha "$value[app-sha]" --arg scenario "$scenario" '{schema:1,attempt_dir:$attempt_dir,qa_root:$qa_root,repository:$repository,source_sha:$source_sha,app_sha:$app_sha,scenario:$scenario}')
EOF

set +e
zsh "$source_root/Scripts/oigo-native-qa-preflight.sh" \
    --profile "$value[profile]" --source-root "$source_root" --app "$app" \
    --app-source-sha "$value[app-source-sha]" --app-sha "$value[app-sha]" \
    --qa-root "$qa_root" --evidence-root "$evidence_root/preflight" \
    --frontmost-app "$target" --target-field-id "$value[target-field-id]" \
    > "$evidence_root/preflight-run.log" 2>&1
preflight_status=$?
set -e
if (( preflight_status != 0 && preflight_status != 2 )); then
    print -u2 "ERROR preflight-failed"
    tail -20 "$evidence_root/preflight-run.log" >&2
    exit 1
fi

app_pid=""
say_pid=""
cleanup() {
    if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true; fi
    if [[ -n "$say_pid" ]]; then kill "$say_pid" 2>/dev/null || true; wait "$say_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

result=INCONCLUSIVE
category=not-run
sequence_file="$evidence_root/physical-sequence.log"
: > "$sequence_file"
initial_target_hash=""
final_target_hash=""
session_status=""
session_raw_bytes=0
session_audio_bytes=0
session_root="$qa_root/home/Library/Application Support/Oigo/Sessions"
before_session_count=0
if [[ -d "$session_root" ]]; then
    before_session_count="$(find "$session_root" -type f -name session.json | wc -l | tr -d ' ')"
fi
if (( preflight_status == 2 )); then
    category=profile-precondition
elif [[ "$scenario" != public-dictation ]]; then
    category="$scenario"
else
    ax="$qa_root/oigo-qa-ax-driver"
    key_driver="$qa_root/oigo-native-key-event-driver"
    set +e
    "$ax" --app "$target" --field-id "$value[target-field-id]" --focus --require-focused --frontmost-checkpoint before-dictation \
        > "$evidence_root/target-focus.log" 2>&1
    focus_status=$?
    initial_target_output="$("$ax" --app "$target" --field-id "$value[target-field-id]" --no-activate --read-value 2>&1)"
    initial_target_status=$?
    set -e
    if (( focus_status != 0 || initial_target_status != 0 )); then
        category=target-focus
    else
        /usr/bin/pbcopy </dev/null
        HOME="$qa_root/home" CFFIXED_USER_HOME="$qa_root/home" CFPREFERENCES_AVOID_DAEMON=1 \
            "$app/Contents/MacOS/Oigo" > "$evidence_root/oigo.log" 2>&1 &
        app_pid=$!
        "$key_driver" --key-code "$value[event-key-code]" --modifiers "$value[event-modifiers]" --edge down >> "$sequence_file"
        print key-down >> "$sequence_file"
        /usr/bin/say -v Samantha "Open the Oigo settings window" > "$evidence_root/say.log" 2>&1 &
        say_pid=$!
        wait "$say_pid"
        say_pid=""
        print say-complete >> "$sequence_file"
        /bin/sleep 2
        print preview-wait-complete >> "$sequence_file"
        "$key_driver" --key-code "$value[event-key-code]" --modifiers "$value[event-modifiers]" --edge up >> "$sequence_file"
        print key-up >> "$sequence_file"
        /bin/sleep 2
        set +e
        target_output="$("$ax" --app "$target" --field-id "$value[target-field-id]" --no-activate --read-value 2>&1)"
        target_status=$?
        set -e
        target_bytes="$(printf '%s' "$target_output" | sed -n 's/.* value=//p' | wc -c | tr -d ' ')"
        initial_target_hash="sha256:$(printf '%s' "$initial_target_output" | shasum -a 256 | awk '{print $1}')"
        final_target_hash="sha256:$(printf '%s' "$target_output" | shasum -a 256 | awk '{print $1}')"
        clipboard_bytes="$(pbpaste 2>/dev/null | wc -c | tr -d ' ')"
        after_session_count=0
        newest_session=""
        if [[ -d "$session_root" ]]; then
            after_session_count="$(find "$session_root" -type f -name session.json | wc -l | tr -d ' ')"
            newest_session="$(find "$session_root" -type f -name session.json -exec stat -f '%m %N' {} + | sort -nr | head -1 | cut -d ' ' -f2-)"
        fi
        if [[ -n "$newest_session" && "$after_session_count" -gt "$before_session_count" ]]; then
            session_status="$(jq -r '.state // empty' "$newest_session" 2>/dev/null || true)"
            session_raw_bytes="$(jq -r '.rawTextByteCount // 0' "$newest_session" 2>/dev/null || print 0)"
            session_audio_bytes="$(jq -r '.audioByteCount // 0' "$newest_session" 2>/dev/null || print 0)"
        fi
        if (( target_status == 0 && target_bytes > 1 && clipboard_bytes > 0 )) \
            && [[ "$initial_target_hash" != "$final_target_hash" ]]; then
            if [[ "$session_status" == completed && "$session_raw_bytes" -gt 0 && "$session_audio_bytes" -gt 0 ]]; then
                result=PASS
                category=public-dictation-complete
            else
                category=finalization-or-durable-session-not-observed
            fi
        else
            category=finalization-or-insertion-not-observed
        fi
    fi
fi

sequence_hash="sha256:$(shasum -a 256 "$sequence_file" | awk '{print $1}')"
payload="$evidence_root/native-qa-payload.json"
atomic_write "$payload" <<EOF
$(jq -n --arg scenario "$scenario" --arg result "$result" --arg category "$category" --arg profile "$value[profile]" --arg sequence_hash "$sequence_hash" --arg initial_target_hash "${initial_target_hash-}" --arg final_target_hash "${final_target_hash-}" --arg session_status "${session_status-}" --argjson session_raw_bytes "${session_raw_bytes:-0}" --argjson session_audio_bytes "${session_audio_bytes:-0}" --argjson preflight_status "$preflight_status" '{scenario:$scenario,result:$result,category:$category,profile:$profile,preflight_exit:$preflight_status,sequence_hash:$sequence_hash,initial_target_hash:$initial_target_hash,final_target_hash:$final_target_hash,session_status:$session_status,session_raw_bytes:$session_raw_bytes,session_audio_bytes:$session_audio_bytes,sequence:["key-down","say","preview-wait","key-up"],native_pass:($result == "PASS"),state_mutated:false}')
EOF
receipt="$evidence_root/native-qa-receipt.json"
zsh "$source_root/Scripts/oigo-qa-write-evidence.sh" \
    --run-marker "$runner_marker" --output "$receipt" --verdict "$result" \
    --source-sha "$value[app-source-sha]" --app-sha "$app_digest" \
    --scenario "$scenario" --payload-file "$payload" >/dev/null

if [[ -n "${value[result-output]-}" ]]; then
    result_output_arg="$value[result-output]"
    result_dir_arg="${result_output_arg:h}"
    [[ -d "$result_dir_arg" && ! -L "$result_dir_arg" ]] || {
        print -u2 "ERROR missing-result-output-parent"
        exit 1
    }
    result_dir="$(cd "$result_dir_arg" && pwd -P)"
    result_output="$result_dir/${result_output_arg:t}"
    [[ "$result_output" == "$qa_root/evidence"/* \
        || "$result_output" == "$repository_root/.omo/evidence/bring-pr-149-home"/* ]] || {
        print -u2 "ERROR result-outside-approved-evidence"
        exit 1
    }
    [[ ! -e "$result_output" && ! -L "$result_output" ]] || {
        print -u2 "ERROR result-output-exists"
        exit 1
    }
    temporary="$(mktemp "$result_dir/.oigo-result.XXXXXX")"
    cp "$receipt" "$temporary"
    /usr/bin/ruby -e 'File.open(ARGV.fetch(0), "r") { |file| file.fsync }' "$temporary"
    mv -f "$temporary" "$result_output"
fi
if [[ -n "${value[jsonl-output]-}" ]]; then
    jsonl_output="${value[jsonl-output]:A}"
    [[ "$jsonl_output" == "$repository_root/.omo/evidence/bring-pr-149-home"/* ]] || {
        print -u2 "ERROR jsonl-outside-repository-evidence"
        exit 1
    }
    row="$evidence_root/native-qa-row.json"
    jq -n --arg scenario "$scenario" --arg result "$result" --arg category "$category" \
        '{scenario:$scenario,result:$result,category:$category}' > "$row"
    zsh "$source_root/Scripts/oigo-native-qa-profile-dispatch.sh" --input "$row" --output "$jsonl_output" >/dev/null
fi
print "$result $scenario category=$category"
