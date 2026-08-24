#!/usr/bin/env bash
# Thin dispatcher for .no-mistakes.yaml. Commands match this repo's SwiftPM
# verify job; this is not the niceuptime Go/frontend driver.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

usage() {
  printf 'usage: %s {format|lint|test}\n' "$0" >&2
  exit 2
}

run() {
  printf '== %s ==\n' "$*"
  "$@"
}

format_sources() {
  # verify.yml and .made.yml have no format step, and this tree has no
  # SwiftFormat / SwiftLint / swift-format config. Do not invent a rewrite.
  printf 'format: this repository has no formatter in CI; nothing to apply\n'
}

lint_sources() {
  # Closest existing static gate: macOS 26 floor metadata (Package.swift,
  # Info.plist, every Xcode configuration).
  run swift run oigo-macos-floor-check
}

test_contracts() {
  # SwiftPM half of .github/workflows/verify.yml (not the Xcode app-bundle job).
  run swift build
  run swift build --product Oigo
  run swift run oigo-macos-floor-check

  local products=(
    oigo-spike-contract-tests
    oigo-issue3-contract-tests
    oigo-issue4-contract-tests
    oigo-issue5-contract-tests
    oigo-issue6-contract-tests
    oigo-issue7-contract-tests
    oigo-issue8-contract-tests
    oigo-issue9-contract-tests
    oigo-issue10-contract-tests
    oigo-issue11-performance-check
    oigo-issue86-contract-tests
    oigo-issue76-contract-tests
    oigo-issue77-contract-tests
    oigo-issue78-contract-tests
    oigo-issue82-contract-tests
    oigo-issue90-contract-tests
    oigo-issue102-contract-tests
    oigo-issue13-dictionary-contract-tests
    oigo-issue14-contract-tests
    oigo-issue92-contract-tests
  )
  local product
  for product in "${products[@]}"; do
    run swift run "$product"
  done
}

if [[ $# -ne 1 ]]; then
  usage
fi

case "$1" in
  format) format_sources ;;
  lint) lint_sources ;;
  test) test_contracts ;;
  *) usage ;;
esac
