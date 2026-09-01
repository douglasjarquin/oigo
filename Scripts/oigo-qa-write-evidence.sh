#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

run_marker="" output="" verdict="" source_sha="" app_sha="" scenario="" payload_file=""
while (( $# > 0 )); do
    [[ $# -ge 2 ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
    case "$1" in
        --run-marker) run_marker="$2" ;;
        --output) output="$2" ;;
        --verdict) verdict="$2" ;;
        --source-sha) source_sha="$2" ;;
        --app-sha) app_sha="$2" ;;
        --scenario) scenario="$2" ;;
        --payload-file) payload_file="$2" ;;
        *) print -u2 "ERROR unknown-argument"; exit 64 ;;
    esac
    shift 2
done
if [[ -z "$run_marker" || -z "$output" || -z "$verdict" || -z "$source_sha" || -z "$scenario" || -z "$payload_file" ]]; then
    print -u2 "ERROR missing-argument"
    exit 64
fi
if ! jq -e 'type == "object" and (.attempt_dir | type == "string")' "$run_marker" >/dev/null 2>&1; then
    print -u2 "ERROR invalid-run-marker"
    exit 1
fi
attempt_dir="$(jq -r .attempt_dir "$run_marker")"
attempt_dir="$(cd "$attempt_dir" && pwd -P)"
output="${output:A}"
if [[ "$output" != "$attempt_dir"/* ]]; then
    print -u2 "ERROR outside-evidence-root"
    exit 1
fi
if [[ -e "$output" ]]; then
    print -u2 "ERROR evidence-exists"
    exit 1
fi
if [[ ! "$source_sha" =~ '^[0-9a-f]{40}$' || ( -n "$app_sha" && ! "$app_sha" =~ '^[0-9a-f]{64}$' ) ]]; then
    print -u2 "ERROR invalid-sha"
    exit 1
fi
if ! jq -e 'type == "object"' "$payload_file" >/dev/null 2>&1; then
    print -u2 "ERROR invalid-evidence-payload"
    exit 1
fi
if LC_ALL=C rg -i '/Users/|raw[_ -]?transcript|clipboard[_ -]?contents?|focused[_ -]?field[_ -]?content|audio[_ -]?contents?|user[_ -]?name' "$payload_file" >/dev/null; then
    print -u2 "ERROR unredacted-evidence"
    exit 1
fi
mkdir -p "${output:h}"
temporary="$(mktemp "${output:h}/.receipt.XXXXXX")"
trap 'rm -f "$temporary"' EXIT INT TERM
jq -n \
    --arg verdict "$verdict" \
    --arg source_sha "$source_sha" \
    --arg app_sha "$app_sha" \
    --arg scenario "$scenario" \
    --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile payload "$payload_file" \
    '{schema:1,verdict:$verdict,source_sha:$source_sha,app_sha:$app_sha,scenario:$scenario,recorded_at:$recorded_at,details:$payload[0]}' > "$temporary"
mv "$temporary" "$output"
trap - EXIT INT TERM
print "EVIDENCE_WRITTEN=${output#$attempt_dir/}"
