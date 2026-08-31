#!/bin/zsh
emulate -L zsh
setopt errexit nounset pipefail

fail() {
    print -u2 -- "ERROR $1"
    exit 1
}

(( $# >= 2 )) || fail invalid-arguments
audit_file=$1
expected_base_sha=$2
shift 2
implementation_sha=""
bundle_sha=""
performance_file=""
while (( $# > 0 )); do
    (( $# >= 2 )) || fail malformed-arguments
    case "$1" in
        --implementation-sha) implementation_sha=$2 ;;
        --bundle-sha) bundle_sha=$2 ;;
        --performance-file) performance_file=$2 ;;
        *) fail unknown-argument ;;
    esac
    shift 2
done
[[ "$expected_base_sha" =~ '^[0-9a-f]{40}$' ]] || fail invalid-base-sha
[[ "$implementation_sha" =~ '^[0-9a-f]{40}$' ]] || fail invalid-implementation-sha
[[ "$bundle_sha" =~ '^[0-9a-f]{64}$' ]] || fail invalid-bundle-sha
[[ -r "$audit_file" ]] || fail missing-audit
[[ -r "$performance_file" ]] || fail missing-performance
grep -Fqx "EXECUTION_BASE_SHA=$expected_base_sha" "$audit_file" || fail base-sha-mismatch
grep -Fqx "IMPLEMENTATION_SHA=$implementation_sha" "$audit_file" || fail implementation-sha-mismatch
grep -Fqx "REVIEWED_PLAN_SHA=4b7cf8d3e0e323b5b3d7e0f17467e5b99901682b81255ad5f06c33ad2e42a198" "$audit_file" || fail reviewed-plan-sha-mismatch
grep -Fqx "BUNDLE_SHA=sha256:$bundle_sha" "$audit_file" || fail bundle-sha-mismatch
grep -Fqx "IMPLEMENTATION_SHA=$implementation_sha" "$performance_file" || fail performance-implementation-sha-mismatch
grep -Fqx "BUNDLE_SHA=sha256:$bundle_sha" "$performance_file" || fail performance-bundle-sha-mismatch
required_rows=(
    status-idle status-activity status-recording status-attention
    menu-start-stop menu-settings-history-quit
    popover-ready popover-recording popover-processing popover-storage-unavailable
    popover-shortcut-inactive popover-microphone-unavailable popover-input-unavailable
    popover-assets-unavailable popover-accessibility-copy-only popover-retry-required
    popover-last-session-actions popover-next-configuration
    hud-preparing hud-recording hud-processing hud-paste-attempted hud-copy-only
    hud-retry-required hud-preserved-failure hud-cancelled hud-interrupted
    onboarding-storage onboarding-microphone-language onboarding-shortcut-insertion
    onboarding-try-it onboarding-done settings-general settings-dictation
    settings-dictionary settings-data-privacy dictionary-actions history-list-detail
    history-toolbar-actions history-paste-again history-stale-load shutdown stale-generation
)
for required_row in $required_rows; do
    grep -Fq "| $required_row |" "$audit_file" || fail missing-required-row
done
while IFS= read -r native_row; do
    [[ "$native_row" == *"APP_BUNDLE_ARTIFACT=sha256:$bundle_sha"* ]] || fail native-pass-without-current-bundle
done < <(grep '^|' "$audit_file" | grep -F 'NATIVE PASS' || true)
for stale in e08081929b8fc0ac5f862e7e8327231b04780644 a3c96c4f3d775ca9cd16ac55d5f68370fa24ab4d e717d74a1d4bfbf16d5fb29496598191cd83cec2; do
    ! grep -Fq "$stale" "$audit_file" || fail stale-audit-binding
done
print -- "PASS ui-audit implementation=$implementation_sha bundle=sha256:$bundle_sha"
