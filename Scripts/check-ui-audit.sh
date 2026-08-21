#!/bin/zsh

emulate -L zsh
setopt errexit nounset pipefail

fail() {
    print -u2 -- "ERROR $1"
    exit 1
}

if (( $# != 2 )); then
    fail invalid-arguments
fi

audit_file=$1
expected_base_sha=$2

if [[ ! $expected_base_sha =~ '^[0-9a-f]{40}$' ]]; then
    fail invalid-base-sha
fi

if [[ ! -f $audit_file || ! -r $audit_file ]]; then
    fail missing-audit
fi

if ! grep -Fqx "BASE_SHA=$expected_base_sha" "$audit_file"; then
    fail base-sha-mismatch
fi

for required_metadata in \
    TASK_01_SHA=e717d74a1d4bfbf16d5fb29496598191cd83cec2 \
    AUDIT_SHA=a3c96c4f3d775ca9cd16ac55d5f68370fa24ab4d \
    UNRELATED_WORKFLOW_RENAME='#140 ci: drop "master" from project workflow'; do
    if ! grep -Fqx "$required_metadata" "$audit_file"; then
        fail missing-required-metadata
    fi
done

required_rows=(
    status-idle
    status-activity
    status-recording
    status-attention
    menu-start-stop
    menu-settings-history-quit
    popover-ready
    popover-recording
    popover-processing
    popover-storage-unavailable
    popover-shortcut-inactive
    popover-microphone-unavailable
    popover-input-unavailable
    popover-assets-unavailable
    popover-accessibility-copy-only
    popover-retry-required
    popover-last-session-actions
    popover-next-configuration
    hud-preparing
    hud-recording
    hud-processing
    hud-paste-attempted
    hud-copy-only
    hud-retry-required
    hud-preserved-failure
    hud-cancelled
    hud-interrupted
    onboarding-storage
    onboarding-microphone-language
    onboarding-shortcut-insertion
    onboarding-try-it
    onboarding-done
    settings-general
    settings-dictation
    settings-dictionary
    settings-data-privacy
    dictionary-actions
    history-list-detail
    history-toolbar-actions
    history-paste-again
    history-stale-load
    shutdown
    stale-generation
)

for required_row in $required_rows; do
    if ! grep -Fq "| $required_row |" "$audit_file"; then
        fail missing-required-row
    fi
done

while IFS= read -r native_row; do
    if [[ ! $native_row =~ 'APP_BUNDLE_ARTIFACT=sha256:[0-9a-f]{64}' ]]; then
        fail native-pass-without-app-bundle-artifact
    fi
done < <(grep '^|' "$audit_file" | grep -F 'NATIVE PASS' || true)

print -- "PASS ui-audit"
