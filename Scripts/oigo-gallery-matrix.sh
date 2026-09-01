#!/bin/bash
set -uo pipefail

source_root=
qa_root=
evidence_root=
appearance=
contrast=
read_only=0

fail() { printf 'ERROR rejected-input:%s\n' "$1" >&2; exit 64; }

while (($# > 0)); do
    case "$1" in
        --source-root) (($# >= 2)) || fail missing-source-root; source_root=$2; shift 2 ;;
        --qa-root) (($# >= 2)) || fail missing-qa-root; qa_root=$2; shift 2 ;;
        --evidence-root) (($# >= 2)) || fail missing-evidence-root; evidence_root=$2; shift 2 ;;
        --appearance) (($# >= 2)) || fail missing-appearance; appearance=$2; shift 2 ;;
        --contrast) (($# >= 2)) || fail missing-contrast; contrast=$2; shift 2 ;;
        --read-only) read_only=1; shift ;;
        *) fail unknown-option ;;
    esac
done

[[ -n "$source_root" && -n "$qa_root" && -n "$evidence_root" && -n "$appearance" && -n "$contrast" ]] || fail missing-argument
[[ "$appearance" == light || "$appearance" == dark || "$appearance" == system ]] || fail invalid-appearance
[[ "$contrast" == standard || "$contrast" == increased ]] || fail invalid-contrast
source_root=$(cd "$source_root" 2>/dev/null && pwd) || fail invalid-source-root
qa_root=$(cd "$qa_root" 2>/dev/null && pwd) || fail invalid-qa-root
repo_root=$(cd "$qa_root/../.." 2>/dev/null && pwd) || fail invalid-qa-root
if [[ ! -d "$evidence_root" ]]; then
    ((read_only)) && fail missing-evidence-root
    mkdir -p "$evidence_root" || fail invalid-evidence-root
fi
evidence_root=$(cd "$evidence_root" 2>/dev/null && pwd) || fail invalid-evidence-root
[[ -f "$source_root/Package.swift" ]] || fail invalid-source-root
[[ -d "$qa_root/home" && -f "$qa_root/run.json" ]] || fail invalid-qa-root
case "$evidence_root" in
    "$repo_root/.omo/evidence/oigo-shortcut-transcription-design-fidelity/task-32"/*|"$repo_root/.omo/evidence/oigo-shortcut-transcription-design-fidelity/task-32") ;;
    *) fail outside-evidence-root ;;
esac

source_sha=$(basename "$source_root" | sed 's/^source-//')
if [[ ! "$source_sha" =~ ^[0-9a-f]{40}$ ]]; then
    source_sha=$(git -C "$source_root" rev-parse HEAD 2>/dev/null || true)
fi
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail invalid-source-sha
integrated_sha=$source_sha

rows='smoke|com.oigo.qa.task01|task-01|
components|com.oigo.qa.task07|task-07|
popover-routing|com.oigo.qa.task11|task-11|
popover-states|com.oigo.qa.task12|task-12/popover-success|
status-states|com.oigo.qa.task20|task-20|
hud-placement|com.oigo.qa.task14|task-14|
hud-states|com.oigo.qa.task15|task-15/hud-states-exhaustive|
paste-again-handoff|com.oigo.qa.task16|task-16|'

overall=0
row_count=0
while IFS='|' read -r scenario suite fixture_subpath; do
    [[ -n "$scenario" ]] || continue
    task_id="task-${suite##*.task}"
    fixture_path="$qa_root/fixtures/native/$fixture_subpath"
    session_path="$qa_root/session/$task_id"
    row_evidence="$evidence_root/$scenario"
    if ((read_only)); then
        [[ -d "$fixture_path" && -d "$session_path" && -d "$row_evidence" ]] || fail missing-fixture
        [[ -f "$row_evidence/exit" && -f "$row_evidence/screenshot-receipt.json" ]] || fail missing-marked-run
        row_exit=$(cat "$row_evidence/exit")
        [[ "$row_exit" == 0 ]] || {
            printf 'ERROR row-failed scenario=%s suite=%s fixture=%s exit=%s category=marked-run-failed\n' \
                "$scenario" "$suite" "$fixture_subpath" "$row_exit" >&2
            overall=1
        }
        row_count=$((row_count + 1))
        continue
    else
        mkdir -p "$fixture_path" "$session_path" "$row_evidence"
    fi
    set +e
    (
        cd "$source_root" || exit 70
        HOME="$qa_root/home" CFFIXED_USER_HOME="$qa_root/home" OIGO_GALLERY_MATRIX=1 timeout 30 swift run OigoUIGallery \
            --scenario "$scenario" \
            --defaults-suite "$suite" \
            --session-root "$session_path" \
            --fixture-root "$fixture_path" \
            --evidence-root "$row_evidence" \
            --pasteboard-provider synthetic \
            --permission-provider synthetic \
            --appearance "$appearance" \
            --contrast "$contrast"
    ) >"$row_evidence/stdout.log" 2>"$row_evidence/stderr.log"
    row_exit=$?
    set -e
    printf '%s\n' "$row_exit" > "$row_evidence/exit"
    receipt_error="$row_evidence/receipt-error.tmp"
    if ! python3 "$source_root/Scripts/oigo-matrix-receipt.py" \
        --root "$row_evidence" \
        --source-sha "$source_sha" \
        --integrated-sha "$integrated_sha" \
        --scenario "$scenario" \
        --appearance "$appearance" \
        --contrast "$contrast" > /dev/null 2> "$receipt_error"; then
        overall=1
        mv "$receipt_error" "$row_evidence/receipt-error.log"
    elif [[ -s "$receipt_error" ]]; then
        mv "$receipt_error" "$row_evidence/receipt-error.log"
        overall=1
    else
        rm -f "$receipt_error"
    fi
    if ((row_exit != 0)); then
        overall=1
        row_category=$(sed -n 's/^ERROR [^:]*:\{0,1\}\([^[:space:]]*\).*$/\1/p' "$row_evidence/stderr.log" | head -1)
        [[ -n "$row_category" ]] || row_category="exit-$row_exit"
        printf 'ERROR row-failed scenario=%s suite=%s fixture=%s exit=%s category=%s\n' \
            "$scenario" "$suite" "$fixture_subpath" "$row_exit" "$row_category" >&2
    fi
    row_count=$((row_count + 1))
done <<< "$rows"

python3 "$source_root/Scripts/oigo-matrix-receipt.py" \
    --aggregate \
    --root "$evidence_root" \
    --source-sha "$source_sha" \
    --integrated-sha "$integrated_sha" \
    --appearance "$appearance" \
    --contrast "$contrast" > /dev/null || overall=1
if ((overall != 0)); then
    printf 'ERROR matrix-failed rows=%s appearance=%s contrast=%s\n' "$row_count" "$appearance" "$contrast" >&2
    exit 1
fi
printf 'PASS gallery-matrix rows=%s appearance=%s contrast=%s source=%s integrated=%s\n' "$row_count" "$appearance" "$contrast" "$source_sha" "$integrated_sha"
