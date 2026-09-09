#!/bin/zsh
set -euo pipefail
path=(/usr/bin /bin /usr/sbin /sbin $path)

if [[ "${1-}" == "--mode" ]]; then
    typeset -A release_value release_seen
    [[ $# -ge 2 && "$2" != --* ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
    release_value[mode]="$2"
    release_seen[mode]=1
    shift 2
    while (( $# > 0 )); do
        [[ $# -ge 2 && "$2" != --* ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
        key="${1#--}"
        [[ "$key" == (mode|source-sha|app-path|derived-data|repo-root|output) ]] || {
            print -u2 "ERROR unknown-argument"
            exit 64
        }
        [[ -z "${release_seen[$key]-}" ]] || { print -u2 "ERROR duplicate-argument"; exit 64; }
        release_seen[$key]=1
        release_value[$key]="$2"
        shift 2
    done
    for key in mode source-sha app-path derived-data repo-root output; do
        [[ -n "${release_value[$key]-}" ]] || { print -u2 "ERROR missing-argument"; exit 64; }
    done
    [[ "${release_value[mode]}" == release && "${release_value[source-sha]}" =~ '^[0-9a-f]{40}$' ]] || {
        print -u2 "ERROR invalid-release-arguments"
        exit 64
    }
    repo_root="${release_value[repo-root]:A}"
    app_path="${release_value[app-path]:A}"
    derived_data="${release_value[derived-data]:A}"
    output="${release_value[output]:A}"
    [[ -d "$repo_root" && -f "$repo_root/Package.swift" ]] || { print -u2 "ERROR invalid-repo-root"; exit 1; }
    repo_head_sha="$(git -C "$repo_root" rev-parse --verify HEAD)"
    [[ "$repo_head_sha" == "${release_value[source-sha]}" ]] || {
        print -u2 "ERROR source-sha-mismatch"
        exit 1
    }
    mkdir -p "$derived_data" "${output:h}"
    [[ ! -e "$output" ]] || { print -u2 "ERROR evidence-exists"; exit 1; }
    build_log="$derived_data/task-10-xcodebuild.log"
    inspect_log="$derived_data/task-10-inspect.log"
    membership_log="$derived_data/task-10-membership.log"
    launch_log="$derived_data/task-10-launch.log"
    temporary="$(mktemp "${output:h}/.task-10-release.XXXXXX")"
    trap 'rm -f "$temporary"' EXIT INT TERM
    overall=0
    {
        print "MODE=release"
        print "SOURCE_SHA=${release_value[source-sha]}"
        print "REPO_HEAD_SHA=$repo_head_sha"
        print "REPO_ROOT=$repo_root"
        print "APP_PATH=$app_path"
        print "DERIVED_DATA=$derived_data"
        print "COMMAND=xcodebuild -project Oigo.xcodeproj -scheme Oigo -configuration Release -sdk macosx -destination platform=macOS,arch=arm64 -derivedDataPath $derived_data ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build"
    } > "$temporary"
    set +e
    xcodebuild -project "$repo_root/Oigo.xcodeproj" -scheme Oigo -configuration Release -sdk macosx \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build \
        > "$build_log" 2>&1
    build_status=$?
    set -e
    print "XCODEBUILD_EXIT=$build_status" >> "$temporary"
    print "XCODEBUILD_LOG=$build_log" >> "$temporary"
    (( build_status == 0 )) || overall=1
    if [[ "$build_status" -eq 0 && -d "$app_path" ]]; then
        set +e
        zsh "$repo_root/Scripts/inspect-oigo-app-bundle.sh" "$app_path" > "$inspect_log" 2>&1
        inspect_status=$?
        python3 "$repo_root/Scripts/check-xcode-source-membership.py" "$repo_root" > "$membership_log" 2>&1
        membership_status=$?
        zsh "$repo_root/Scripts/bounded-oigo-launch.sh" "$app_path" > "$launch_log" 2>&1
        launch_status=$?
        set -e
        app_bundle_sha="$(zsh "$repo_root/Scripts/oigo-bundle-sha256.sh" "$app_path" | sed -n 's/^APP_BUNDLE_SHA=//p')"
        executable_sha="$(shasum -a 256 "$app_path/Contents/MacOS/Oigo" | awk '{print $1}')"
        print "INSPECT_EXIT=$inspect_status" >> "$temporary"
        print "INSPECT_LOG=$inspect_log" >> "$temporary"
        print "SOURCE_MEMBERSHIP_EXIT=$membership_status" >> "$temporary"
        print "SOURCE_MEMBERSHIP_LOG=$membership_log" >> "$temporary"
        print "BOUNDED_LAUNCH_EXIT=$launch_status" >> "$temporary"
        print "BOUNDED_LAUNCH_LOG=$launch_log" >> "$temporary"
        print "EXECUTABLE_SHA256=$executable_sha" >> "$temporary"
        print "APP_BUNDLE_SHA=$app_bundle_sha" >> "$temporary"
        (( inspect_status == 0 && membership_status == 0 && launch_status == 0 )) || overall=1
    else
        print "INSPECT_EXIT=not-run" >> "$temporary"
        print "SOURCE_MEMBERSHIP_EXIT=not-run" >> "$temporary"
        print "BOUNDED_LAUNCH_EXIT=not-run" >> "$temporary"
        overall=1
    fi
    /usr/bin/ruby -e 'File.open(ARGV.fetch(0), "r") { |file| file.fsync }' "$temporary"
    mv "$temporary" "$output"
    trap - EXIT INT TERM
    print "RELEASE_EVIDENCE_WRITTEN=$output"
    exit "$overall"
fi

run_marker="" output="" verdict="" source_sha="" app_sha="" scenario="" payload_file=""
while (( $# > 0 )); do
    [[ $# -ge 2 ]] || { print -u2 "ERROR malformed-arguments"; exit 64; }
    case "$1" in
        --run-marker) run_marker="$2" ;;
        --output) output="$2" ;;
        --verdict) verdict="$2" ;;
        --source-sha) source_sha="$2" ;;
        --app-sha) app_sha="$2" ;;
        --scenario) scenario="$2" ;;
        --payload-file) payload_file="$2" ;;
        *) print -u2 "ERROR unknown-argument"; exit 64 ;;
    esac
    shift 2
done
if [[ -z "$run_marker" || -z "$output" || -z "$verdict" || -z "$source_sha" || -z "$scenario" || -z "$payload_file" ]]; then
    print -u2 "ERROR missing-argument"
    exit 64
fi
if ! jq -e 'type == "object" and (.attempt_dir | type == "string")' "$run_marker" >/dev/null 2>&1; then
    print -u2 "ERROR invalid-run-marker"
    exit 1
fi
attempt_dir="$(jq -r .attempt_dir "$run_marker")"
attempt_dir="$(cd "$attempt_dir" && pwd -P)"
output="${output:A}"
if [[ "$output" != "$attempt_dir"/* ]]; then
    print -u2 "ERROR outside-evidence-root"
    exit 1
fi
if [[ -e "$output" ]]; then
    print -u2 "ERROR evidence-exists"
    exit 1
fi
if [[ ! "$source_sha" =~ '^[0-9a-f]{40}$' || ( -n "$app_sha" && ! "$app_sha" =~ '^[0-9a-f]{64}$' ) ]]; then
    print -u2 "ERROR invalid-sha"
    exit 1
fi
if ! jq -e 'type == "object"' "$payload_file" >/dev/null 2>&1; then
    print -u2 "ERROR invalid-evidence-payload"
    exit 1
fi
if LC_ALL=C rg -i '/Users/|raw[_ -]?transcript|clipboard[_ -]?contents?|focused[_ -]?field[_ -]?content|audio[_ -]?contents?|user[_ -]?name' "$payload_file" >/dev/null; then
    print -u2 "ERROR unredacted-evidence"
    exit 1
fi
mkdir -p "${output:h}"
temporary="$(mktemp "${output:h}/.receipt.XXXXXX")"
trap 'rm -f "$temporary"' EXIT INT TERM
jq -n \
    --arg verdict "$verdict" \
    --arg source_sha "$source_sha" \
    --arg app_sha "$app_sha" \
    --arg scenario "$scenario" \
    --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile payload "$payload_file" \
    '{schema:1,verdict:$verdict,source_sha:$source_sha,app_sha:$app_sha,scenario:$scenario,recorded_at:$recorded_at,details:$payload[0]}' > "$temporary"
mv "$temporary" "$output"
trap - EXIT INT TERM
print "EVIDENCE_WRITTEN=${output#$attempt_dir/}"
