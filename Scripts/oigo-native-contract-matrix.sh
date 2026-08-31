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
[[ "$integrated_sha" =~ ^[0-9a-f]{40}$ ]] || fail invalid-integrated-sha

rows='smoke|com.oigo.qa.task01|task-01|
design-coverage|com.oigo.qa.task02|task-02|
presentation-inputs|com.oigo.qa.task03|task-03|
presentation-matrix|com.oigo.qa.task04|task-04|
app-delegate-publication|com.oigo.qa.task05|task-05|
component-contracts|com.oigo.qa.task06|task-06|
gallery-components|com.oigo.qa.task07|task-07|
identity|com.oigo.qa.task09|task-09|
popover-routing|com.oigo.qa.task11|task-11|primary-secondary-control-click
popover-state-matrix|com.oigo.qa.task12|task-12|exhaustive
popover-actions|com.oigo.qa.task13|task-13|
hud-placement|com.oigo.qa.task14|task-14|
hud-baseline|com.oigo.qa.task15|task-15/hud-baseline|
hud-states|com.oigo.qa.task15|task-15/hud-states-exhaustive|exhaustive
paste-again-handoff|com.oigo.qa.task16|task-16|
onboarding-flow|com.oigo.qa.task17|task-17|
settings-panes|com.oigo.qa.task18|task-18|
history-workspace|com.oigo.qa.task19|task-19|
integrated-ui|com.oigo.qa.task20|task-20|'

write_if_missing() {
    path=$1
    value=$2
    [[ -e "$path" ]] && return 0
    ((read_only)) && fail missing-fixture
    mkdir -p "$(dirname "$path")" || fail cannot-materialize-fixture
    printf '%s\n' "$value" > "$path" || fail cannot-materialize-fixture
}

copy_if_missing() {
    destination=$1
    origin=$2
    [[ -e "$destination" ]] && return 0
    ((read_only)) && fail missing-fixture
    [[ -e "$origin" ]] || fail missing-fixture-template
    mkdir -p "$(dirname "$destination")" || fail cannot-materialize-fixture
    cp "$origin" "$destination" || fail cannot-materialize-fixture
}

rows_json='["storage-checking","storage-ready-idle","storage-unavailable","shortcut-inactive-conflict","mic-permission-unavailable","selected-input-unavailable","language-assets-checking-installing","language-assets-unavailable","accessibility-unavailable","preparing","recording","finalizing-cleaning-inserting","paste-event-attempted","paste-owned-field-verified","copied-only","cleanup-fallback","insertion-failure","retry-required","cancelled-before-durable-raw","cancelled-after-durable-raw","interrupted","busy-typed-reason","shutting-down"]'
task7_components='[{"id":"destructive-confirmation","accessibilityRole":"button","accessibilityLabel":"Delete synthetic item","accessibilityActions":["press"],"focusOrder":1,"keyActivations":["Return","Space"]},{"id":"empty-state","accessibilityRole":"group","accessibilityLabel":"No synthetic entries","accessibilityActions":[],"focusOrder":null,"keyActivations":[]},{"id":"field-help-text","accessibilityRole":"staticText","accessibilityLabel":"Synthetic helper text","accessibilityActions":[],"focusOrder":null,"keyActivations":[]},{"id":"floating-panel","accessibilityRole":"window","accessibilityLabel":"Synthetic floating panel","accessibilityActions":[],"focusOrder":null,"keyActivations":[]},{"id":"form-row","accessibilityRole":"group","accessibilityLabel":"Synthetic form row","accessibilityActions":[],"focusOrder":null,"keyActivations":[]},{"id":"inline-notice","accessibilityRole":"button","accessibilityLabel":"Synthetic notice","accessibilityActions":["press"],"focusOrder":2,"keyActivations":["Return","Space"]},{"id":"loading-state","accessibilityRole":"group","accessibilityLabel":"Synthetic loading","accessibilityActions":[],"focusOrder":null,"keyActivations":[]},{"id":"permission-row","accessibilityRole":"button","accessibilityLabel":"Synthetic permission","accessibilityActions":["press"],"focusOrder":3,"keyActivations":["Return","Space"]},{"id":"section-header","accessibilityRole":"staticText","accessibilityLabel":"Synthetic section","accessibilityActions":[],"focusOrder":null,"keyActivations":[]},{"id":"shortcut-presentation","accessibilityRole":"group","accessibilityLabel":"Command Shift D","accessibilityActions":[],"focusOrder":null,"keyActivations":[]},{"id":"status-badge","accessibilityRole":"group","accessibilityLabel":"Review","accessibilityActions":[],"focusOrder":null,"keyActivations":[]},{"id":"status-row","accessibilityRole":"group","accessibilityLabel":"Synthetic service, Ready","accessibilityActions":[],"focusOrder":null,"keyActivations":[]},{"id":"storage-health-row","accessibilityRole":"button","accessibilityLabel":"Synthetic storage","accessibilityActions":["press"],"focusOrder":4,"keyActivations":["Return","Space"]},{"id":"transcript-view","accessibilityRole":"button","accessibilityLabel":"Synthetic transcript","accessibilityActions":["press"],"focusOrder":5,"keyActivations":["Return","Space"]}]'

if ((read_only == 0)); then
    mkdir -p "$qa_root/home" "$evidence_root"
    write_if_missing "$qa_root/fixtures/native/task-03/fixture.json" '{"snapshot":{"generation":10,"storage":"ready"},"generations":{"current":10,"candidate":11},"dirty":false,"result":{"reportedSuccess":false,"processExitStatus":0},"repeatCount":2}'
    write_if_missing "$qa_root/fixtures/native/task-04/fixture.json" "{\"mode\":\"exhaustive\",\"rows\":$rows_json,\"generations\":{\"current\":10,\"candidate\":11},\"dirty\":false,\"enumeration\":[\"single\"],\"result\":{\"reportedSuccess\":false,\"processExitStatus\":0}}"
    write_if_missing "$qa_root/fixtures/native/task-05/fixture.json" '{"mode":"fanout","events":[{"generation":1,"delayMilliseconds":0,"storage":"ready"},{"generation":2,"delayMilliseconds":10,"storage":"unavailable"}],"surfaceCount":6,"repeatCount":1,"dirty":false,"result":{"reportedSuccess":false,"processExitStatus":0}}'
    write_if_missing "$qa_root/fixtures/native/task-07/fixture.json" "{\"scenarios\":[\"components\"],\"appearanceStates\":[\"light\",\"dark\"],\"textSizes\":[\"normal\",\"large\"],\"reducedMotion\":true,\"pasteboardProvider\":\"synthetic\",\"permissionProvider\":\"synthetic\",\"components\":$task7_components,\"panel\":{\"nonactivating\":true,\"canBecomeKey\":false,\"canBecomeMain\":false},\"lifecycle\":{\"transcriptClearable\":true,\"loadingStops\":true,\"panelTerminalizes\":true},\"selection\":{\"selectedMode\":\"Dark + Large Text\",\"selectedValue\":\"selected\",\"focusedElement\":\"Synthetic permission\",\"persistentVisualTreatment\":\"accent-fill-and-border\"},\"longLabelLayout\":{\"viewportWidth\":760,\"measuredWidth\":760,\"wrapped\":true,\"controlsVisible\":true},\"focusObservations\":[[\"destructive-confirmation\",\"inline-notice\",\"permission-row\",\"storage-health-row\",\"transcript-view\"],[\"destructive-confirmation\",\"inline-notice\",\"permission-row\",\"storage-health-row\",\"transcript-view\"]],\"dirty\":false,\"result\":{\"reportedSuccess\":false,\"processExitStatus\":0}}"
    copy_if_missing "$qa_root/fixtures/native/task-11/primary-secondary-control-click.json" "$source_root/Tests/OigoNativeUIContractFixtures/task-11/primary-secondary-control-click.json"
    copy_if_missing "$qa_root/fixtures/native/task-13/fixture.json" "$source_root/Tests/OigoNativeUIContractFixtures/task-13/bounded-summary-and-rollback/fixture.json"
    copy_if_missing "$qa_root/fixtures/native/task-14/fixture.json" "$source_root/Fixtures/native-ui/task-14/multi-display-negative-origin.json"
    copy_if_missing "$qa_root/fixtures/native/task-15/hud-baseline/fixture.json" "$source_root/Fixtures/native-ui/task-15/hud-baseline.json"
    copy_if_missing "$qa_root/fixtures/native/task-15/hud-states-exhaustive/fixture.json" "$source_root/Fixtures/native-ui/task-15/hud-states-exhaustive.json"
    copy_if_missing "$qa_root/fixtures/native/task-16/fixture.json" "$source_root/Tests/OigoNativeUIContractFixtures/task-16/success-copy-only-timeout-cancel/fixture.json"
fi

overall=0
row_count=0
while IFS='|' read -r scenario suite fixture_subpath special; do
    [[ -n "$scenario" ]] || continue
    fixture_path="$qa_root/fixtures/native/$fixture_subpath"
    row_evidence="$evidence_root/$scenario"
    if ((read_only)); then
        [[ -d "$fixture_path" && -d "$row_evidence" ]] || { overall=1; continue; }
    else
        mkdir -p "$fixture_path" "$row_evidence"
    fi
    if [[ -n "$special" ]]; then
        set +e
        (cd "$source_root" && HOME="$qa_root/home" CFFIXED_USER_HOME="$qa_root/home" timeout 180 swift run oigo-native-ui-contract-tests --scenario "$scenario" --defaults-suite "$suite" --fixture-root "$fixture_path" --evidence-root "$row_evidence" --appearance "$appearance" --contrast "$contrast" --fixture "$special") >"$row_evidence/stdout.log" 2>"$row_evidence/stderr.log"
        row_exit=$?
        set -e
    else
        set +e
        (cd "$source_root" && HOME="$qa_root/home" CFFIXED_USER_HOME="$qa_root/home" timeout 180 swift run oigo-native-ui-contract-tests --scenario "$scenario" --defaults-suite "$suite" --fixture-root "$fixture_path" --evidence-root "$row_evidence" --appearance "$appearance" --contrast "$contrast") >"$row_evidence/stdout.log" 2>"$row_evidence/stderr.log"
        row_exit=$?
        set -e
    fi
    printf '%s\n' "$row_exit" > "$row_evidence/exit"
    receipt_error="$row_evidence/receipt-error.tmp"
    if ! python3 "$source_root/Scripts/oigo-matrix-receipt.py" --root "$row_evidence" --source-sha "$source_sha" --integrated-sha "$integrated_sha" --scenario "$scenario" --appearance "$appearance" --contrast "$contrast" > /dev/null 2> "$receipt_error"; then
        overall=1
        mv "$receipt_error" "$row_evidence/receipt-error.log"
    elif [[ -s "$receipt_error" ]]; then
        mv "$receipt_error" "$row_evidence/receipt-error.log"
        overall=1
    else
        rm -f "$receipt_error"
    fi
    ((row_exit != 0)) && overall=1
    if ((row_exit != 0)); then
        row_category=$(sed -n 's/^ERROR [^:]*:\{0,1\}\([^[:space:]]*\).*$/\1/p' "$row_evidence/stderr.log" | head -1)
        [[ -n "$row_category" ]] || row_category="exit-$row_exit"
        printf 'ERROR row-failed scenario=%s suite=%s fixture=%s exit=%s category=%s\n' \
            "$scenario" "$suite" "$fixture_subpath" "$row_exit" "$row_category" >&2
    fi
    row_count=$((row_count + 1))
done <<< "$rows"

python3 "$source_root/Scripts/oigo-matrix-receipt.py" --aggregate --root "$evidence_root" --source-sha "$source_sha" --integrated-sha "$integrated_sha" --appearance "$appearance" --contrast "$contrast" > /dev/null || overall=1
if ((overall != 0)); then
    printf 'ERROR matrix-failed rows=%s appearance=%s contrast=%s\n' "$row_count" "$appearance" "$contrast" >&2
    exit 1
fi
printf 'PASS native-contract-matrix rows=%s appearance=%s contrast=%s source=%s integrated=%s\n' "$row_count" "$appearance" "$contrast" "$source_sha" "$integrated_sha"
