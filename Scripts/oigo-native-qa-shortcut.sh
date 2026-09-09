#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

home="" bundle_id="" mode="" key_code="" modifiers=""
while (( $# > 0 )); do
    case "$1" in
        --write-default|--read)
            [[ -z "$mode" ]] || { print -u2 "ERROR duplicate-mode"; exit 64; }
            mode="${1#--}"
            shift
            ;;
        --home|--bundle-id|--key-code|--modifiers|--expect-key-code|--expect-modifiers)
            [[ $# -ge 2 && "$2" != --* ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
            case "$1" in
                --home) home="$2" ;;
                --bundle-id) bundle_id="$2" ;;
                --key-code|--expect-key-code) key_code="$2" ;;
                --modifiers|--expect-modifiers) modifiers="$2" ;;
            esac
            shift 2
            ;;
        *) print -u2 "ERROR unknown-argument"; exit 64 ;;
    esac
done
[[ -n "$home" && -n "$bundle_id" && -n "$mode" && -n "$key_code" && -n "$modifiers" ]] || {
    print -u2 "ERROR missing-argument"
    exit 64
}
[[ "$bundle_id" == "com.oigo.app" && "$key_code" =~ '^[0-9]+$' && "$modifiers" == "shift,command" ]] || {
    print -u2 "ERROR invalid-shortcut"
    exit 64
}
mkdir -p "$home/Library/Preferences"
home="$(cd "$home" && pwd -P)"
[[ "${HOME:A}" == "$home" ]] || { print -u2 "ERROR nonisolated-home"; exit 1; }
export HOME="$home" CFFIXED_USER_HOME="$home" CFPREFERENCES_AVOID_DAEMON=1

settings='{"globalShortcut":{"keyCode":49,"modifiers":768},"localeIdentifier":"en_US","defaultMode":"instant","showVolatilePreview":true,"audioRetention":"oneDay","keepSuccessfulAudioIndefinitely":false,"launchAtLogin":false,"selectedInput":{"systemDefault":{}},"selectedInputChannel":0}'
encoded="$(printf '%s' "$settings" | xxd -p -c 9999)"
if [[ "$mode" == "write-default" ]]; then
    defaults write "$bundle_id" oigo.settings.v1 -data "$encoded"
fi
stored="$(defaults export "$bundle_id" - 2>/dev/null | awk '
    /<key>oigo\.settings\.v1<\/key>/ { in_data=1; next }
    in_data == 1 && /<data>/ { in_data=2; next }
    in_data == 2 && /<\/data>/ { exit }
    in_data == 2 { printf "%s", $0 }
')"
[[ -n "$stored" ]] || { print -u2 "ERROR shortcut-unavailable"; exit 1; }
decoded="$(printf '%s' "$stored" | tr -d '[:space:]' | base64 -D 2>/dev/null || true)"
observed_key="$(jq -r '.globalShortcut.keyCode // empty' <<< "$decoded" 2>/dev/null || true)"
observed_modifiers="$(jq -r '.globalShortcut.modifiers // empty' <<< "$decoded" 2>/dev/null || true)"
[[ "$observed_key" == "$key_code" && "$observed_modifiers" == "768" ]] || {
    print -u2 "ERROR shortcut-mismatch"
    exit 1
}
print "SHORTCUT_KEY_CODE=$observed_key"
print "SHORTCUT_MODIFIERS=$modifiers"
print "SHORTCUT_DEFAULTS_HOME=$home"
