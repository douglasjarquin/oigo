#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

case_name="" evidence_root=""
while (( $# > 0 )); do
    [[ $# -ge 2 && "$2" != --* ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
    case "$1" in
        --case) [[ -z "$case_name" ]] || { print -u2 "ERROR duplicate-argument"; exit 64; }; case_name="$2" ;;
        --evidence-root) [[ -z "$evidence_root" ]] || { print -u2 "ERROR duplicate-argument"; exit 64; }; evidence_root="$2" ;;
        *) print -u2 "ERROR unknown-argument"; exit 64 ;;
    esac
    shift 2
done
[[ -n "$case_name" && -n "$evidence_root" ]] || { print -u2 "ERROR missing-argument"; exit 64; }
case "$case_name" in
    misleading-success|stale-generation|dirty-worktree|invalid-marker|unavailable-resource|failing-contract) ;;
    *) print -u2 "ERROR unsupported-case"; exit 64 ;;
esac

evidence_root="${evidence_root:A}"
mkdir -p "$evidence_root"
result="$evidence_root/result.txt"
[[ ! -e "$result" ]] || { print -u2 "ERROR result-exists"; exit 1; }
print "ERROR case=$case_name" > "$result"
print "FAILURE_FIXTURE case=$case_name"
exit 1
