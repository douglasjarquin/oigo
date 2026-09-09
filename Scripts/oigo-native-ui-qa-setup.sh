#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

typeset -A value
while (( $# > 0 )); do
    [[ $# -ge 2 && "$2" != --* ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
    key="${1#--}"
    [[ "$key" == (source-root|source-sha|qa-root|evidence-root) ]] || {
        print -u2 "ERROR unknown-argument"
        exit 64
    }
    [[ -z "${value[$key]-}" ]] || { print -u2 "ERROR duplicate-argument"; exit 64; }
    value[$key]="$2"
    shift 2
done
for key in source-root source-sha qa-root evidence-root; do
    [[ -n "${value[$key]-}" ]] || { print -u2 "ERROR missing-argument"; exit 64; }
done

source_root="${value[source-root]:A}"
qa_root_logical="$(cd "${value[qa-root]}" && pwd -L)"
qa_root="$(cd "${value[qa-root]}" && pwd -P)"
normalize_tmp_alias() {
    local path="$1"
    if [[ "$path" == /tmp ]]; then
        print -r -- /private/tmp
    elif [[ "$path" == /tmp/* ]]; then
        print -r -- "/private${path}"
    else
        print -r -- "$path"
    fi
}
[[ "$(normalize_tmp_alias "$qa_root_logical")" == "$qa_root" ]] || {
    print -u2 "ERROR symlinked-qa-root"
    exit 1
}
evidence_parent_arg="${value[evidence-root]:h}"
[[ -d "$evidence_parent_arg" && ! -L "$evidence_parent_arg" ]] || { print -u2 "ERROR unsafe-evidence-parent"; exit 1; }
evidence_parent_logical="$(cd "$evidence_parent_arg" && pwd -L)"
evidence_parent="$(cd "$evidence_parent_arg" && pwd -P)"
[[ "$(normalize_tmp_alias "$evidence_parent_logical")" == "$evidence_parent" ]] || {
    print -u2 "ERROR symlinked-evidence-parent"
    exit 1
}
evidence_root="$evidence_parent/${value[evidence-root]:t}"
evidence_root_logical="$evidence_parent_logical/${value[evidence-root]:t}"
[[ "$evidence_root" == "$qa_root/evidence" || "$evidence_root" == "$qa_root/evidence"/* ]] || { print -u2 "ERROR evidence-root-outside-qa-root"; exit 1; }
[[ ! -L "$evidence_root" ]] || { print -u2 "ERROR symlinked-evidence-root"; exit 1; }
source_sha="${value[source-sha]}"
[[ "$source_sha" =~ '^[0-9a-f]{40}$' && -f "$source_root/Package.swift" ]] || {
    print -u2 "ERROR invalid-source"
    exit 1
}
[[ "$(git -C "$source_root" rev-parse --verify HEAD)" == "$source_sha" ]] || {
    print -u2 "ERROR source-sha-mismatch"
    exit 1
}

mkdir -p "$qa_root/evidence" "$qa_root/fixtures/native/task-20" \
    "$qa_root/fixtures/native/task-21" "$qa_root/fixtures/native/task-31" \
    "$qa_root/fixtures/metadata"
marker="$qa_root/native-ui-qa-marker.json"
run_uuid="$(uuidgen)"
chflags nouchg "$marker" 2>/dev/null || true
jq -n \
    --arg qa_root "$qa_root_logical" \
    --arg repository "$source_root" \
    --arg source_sha "$source_sha" \
    --arg attempt_dir "$evidence_root_logical" \
    --arg run_uuid "$run_uuid" \
    '{schema:1,qa_root:$qa_root,repository:$repository,source_sha:$source_sha,attempt_dir:$attempt_dir,run_uuid:$run_uuid}' \
    > "$marker.tmp"
/usr/bin/ruby -e 'File.open(ARGV.fetch(0), "r") { |file| file.fsync }' "$marker.tmp"
mv "$marker.tmp" "$marker"
chmod 444 "$marker"
chflags uchg "$marker" 2>/dev/null || true
jq -n --arg source_sha "$source_sha" \
    '{schema:1,source_sha:$source_sha,fixtures:"deterministic-ui-only"}' \
    > "$qa_root/fixtures/metadata/fixture-metadata.json"
jq -n \
    --arg name "task-21-shell" \
    '{name:$name,mode:"shell",width:340,contentWidth:308,sidePadding:16,primaryActionHeight:30,sections:["header","primary-action","shortcut","mode","microphone","latest-dictation","footer"],dirty:false}' \
    > "$qa_root/fixtures/native/task-21/fixture.json"
jq -n \
    '{scenario:"cross-surface",fixture:"cross-surface-success",committedShortcutKeyCode:0,committedShortcutModifiers:"command",flow:"happy",expectedRoutes:["start-dictation","stop-dictation","retry-storage","retry-transcription","choose-input","install-assets","open-settings","open-system-settings","set-mode-instant","set-mode-clean","open-data-location","copy","paste-again","open-history","quit"]}' \
    > "$qa_root/fixtures/native/task-31/fixture.json"
print "UI_QA_SETUP_READY=$qa_root"
print "SOURCE_SHA=$source_sha"
print "MARKER=$marker"
