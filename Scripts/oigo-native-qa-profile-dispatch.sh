#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

input="" output=""
while (( $# > 0 )); do
    [[ $# -ge 2 && "$2" != --* ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
    case "$1" in
        --input) input="$2" ;;
        --output) output="$2" ;;
        *) print -u2 "ERROR unknown-argument"; exit 64 ;;
    esac
    shift 2
done
[[ -n "$input" && -n "$output" ]] || { print -u2 "ERROR missing-argument"; exit 64; }
jq -e 'type == "object" and (.scenario | type == "string") and (.result | type == "string")' "$input" >/dev/null || {
    print -u2 "ERROR invalid-result-row"
    exit 1
}
"${0:A:h}/oigo-qa-append-jsonl.sh" --input "$input" --output "$output"
