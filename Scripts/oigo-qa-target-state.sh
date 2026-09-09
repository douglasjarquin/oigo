#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

target="" field_id="" expect_value=""
while (( $# > 0 )); do
    [[ $# -ge 2 && "$2" != --* ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
    case "$1" in
        --target) target="$2" ;;
        --field-id) field_id="$2" ;;
        --expect-value) expect_value="$2" ;;
        *) print -u2 "ERROR unknown-argument"; exit 64 ;;
    esac
    shift 2
done
[[ -n "$target" && -n "$field_id" ]] || { print -u2 "ERROR missing-argument"; exit 64; }
[[ -d "$target" ]] || { print -u2 "ERROR missing-target-bundle"; exit 1; }
declared="$(/usr/libexec/PlistBuddy -c 'Print :OigoQATargetFieldIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)"
[[ "$declared" == "$field_id" && "$bundle_id" == "com.oigo.qa.target" ]] || { print -u2 "ERROR target-identity-mismatch"; exit 1; }
if [[ -n "$expect_value" ]]; then
    output="$("${0:A:h}/../${AX_DRIVER_PATH-oigo-qa-ax-driver}" --app "$target" --field-id "$field_id" --read-value)"
    [[ "$output" == *"value=$expect_value" ]] || { print -u2 "ERROR target-value-mismatch"; exit 1; }
fi
print "TARGET_BUNDLE_ID=$bundle_id"
print "TARGET_FIELD_ID=$field_id"
