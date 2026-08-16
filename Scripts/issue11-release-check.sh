#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 "usage: $0 <sanitized-measurements.json>"
    exit 64
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$repo_root"
DEVELOPER_DIR="$developer_dir" swift run oigo-issue11-performance-check
DEVELOPER_DIR="$developer_dir" swift run oigo-issue11-performance-check --input "$1"
