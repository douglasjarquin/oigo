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
[[ -f "$input" ]] || { print -u2 "ERROR missing-input"; exit 1; }
output="${output:A}"
mkdir -p "${output:h}"
lock="$output.lock"
mkdir "$lock" 2>/dev/null || { print -u2 "ERROR output-locked"; exit 1; }
temporary="$(mktemp "${output:h}/.jsonl-row.XXXXXX")"
trap 'rm -f "$temporary"; rmdir "$lock" 2>/dev/null || true' EXIT INT TERM
jq -ce 'select(type == "object")' "$input" > "$temporary" || { print -u2 "ERROR invalid-json-object"; exit 1; }
[[ "$(wc -l < "$temporary" | tr -d ' ')" == "1" ]] || { print -u2 "ERROR invalid-json-object"; exit 1; }
/usr/bin/ruby -e 'File.open(ARGV.fetch(0), "r") { |file| file.fsync }' "$temporary"
print -rn -- "$(<"$temporary")"$'\n' >> "$output"
/usr/bin/ruby -e 'File.open(ARGV.fetch(0), "r") { |file| file.fsync }' "$output"
rm -f "$temporary"
rmdir "$lock"
trap - EXIT INT TERM
print "JSONL_APPENDED=$output"
