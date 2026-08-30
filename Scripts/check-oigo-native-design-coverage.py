#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///

# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly (no venv, no pip install needed):
#      python3 Scripts/check-oigo-native-design-coverage.py docs/native-design-coverage.json
# 3. Or make executable and run:
#      chmod +x Scripts/check-oigo-native-design-coverage.py && ./Scripts/check-oigo-native-design-coverage.py docs/native-design-coverage.json
# ──────────────────

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


class CoverageError(Exception):
    def __init__(self, category: str) -> None:
        super().__init__(category)
        self.category = category


def repository_root() -> Path:
    return Path(__file__).resolve().parent.parent


def parse_arguments() -> Path:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    return parser.parse_args().manifest


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        content = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CoverageError("malformed-manifest") from error
    if not isinstance(content, dict):
        raise CoverageError("malformed-manifest")
    expected_keys = {
        "schema_version",
        "native_surfaces",
        "excluded_website_artifacts",
        "state_matrix_rows",
        "hud",
        "geometry_pt",
        "design_tokens",
        "shortcut",
    }
    if set(content) != expected_keys:
        raise CoverageError("unsupported-manifest-key")
    if content["schema_version"] != 1:
        raise CoverageError("unsupported-schema-version")
    return content


def native_surfaces_from_handoff(root: Path) -> list[str]:
    handoff = (root / "design/docs/handoff.md").read_text(encoding="utf-8")
    return re.findall(r"^- `([^`]+\.dc\.html)`", handoff, flags=re.MULTILINE)


def state_matrix_rows_from_document(root: Path) -> list[str]:
    matrix = (root / "design/docs/ui-state-matrix.md").read_text(encoding="utf-8")
    rows: list[str] = []
    for line in matrix.splitlines():
        columns = line.split("|")
        if len(columns) == 9 and columns[1].strip() not in {"state", "---"}:
            rows.append(columns[1].strip())
    return rows


def hud_states_from_source(root: Path) -> list[str]:
    source = (root / "Sources/Oigo/UI/HUD/OigoHUDState.swift").read_text(encoding="utf-8")
    enum_match = re.search(
        r"public enum OigoHUDState:.*?\{(.*?)^}\s*$", source, flags=re.MULTILINE | re.DOTALL
    )
    if enum_match is None:
        raise CoverageError("hud-state-source-unreadable")
    return re.findall(r"^    case ([A-Za-z][A-Za-z0-9]*)", enum_match.group(1), flags=re.MULTILINE)


def require_exact_list(value: Any, expected: list[str], missing_category: str) -> None:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise CoverageError("malformed-manifest")
    missing = set(expected) - set(value)
    extras = set(value) - set(expected)
    if missing:
        raise CoverageError(missing_category)
    if extras or len(value) != len(expected):
        raise CoverageError("unexpected-coverage-entry")


def require_mapping(value: Any, expected: dict[str, Any], category: str) -> None:
    if value != expected:
        raise CoverageError(category)


def contains_literal_shortcut(value: Any) -> bool:
    if isinstance(value, dict):
        return any(contains_literal_shortcut(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_literal_shortcut(item) for item in value)
    if not isinstance(value, str):
        return False
    return bool(re.search(r"(?:⌥|Option\+|Alt\+|Cmd\+|Command\+).+", value))


def validate_hud(manifest: dict[str, Any], expected_states: list[str]) -> None:
    hud = manifest["hud"]
    if not isinstance(hud, dict):
        raise CoverageError("malformed-manifest")
    expected_hud = {
        "visible_content_frame_pt",
        "screen_map_outer_width_pt",
        "corner_radius_pt",
        "state_assignments",
    }
    if set(hud) != expected_hud:
        raise CoverageError("unsupported-manifest-key")
    require_mapping(
        hud["visible_content_frame_pt"],
        {
            "compact": {"width": 224, "height": 42},
            "expanded": {"width": 280, "height": 64},
        },
        "invalid-hud-content-frame",
    )
    require_mapping(
        hud["screen_map_outer_width_pt"], {"min": 210, "max": 280}, "invalid-hud-screen-map-width"
    )
    if hud["corner_radius_pt"] != 12:
        raise CoverageError("invalid-hud-corner-radius")
    assignments = hud["state_assignments"]
    if not isinstance(assignments, dict):
        raise CoverageError("malformed-manifest")
    if set(assignments) != set(expected_states):
        raise CoverageError("unassigned-hud-state")
    compact = {"preparing", "degradedRecording", "finalizing", "cleaning", "pasting", "terminal", "shutdown"}
    expanded = {
        "pasteAttempted",
        "copied",
        "copyOnly",
        "savedRetry",
        "preservedFailure",
        "cleanupFallback",
        "cancelledBeforeRaw",
        "cancelledAfterRaw",
        "interrupted",
        "pasteAgainDestination",
    }
    for state in compact:
        if assignments.get(state) != "compact":
            raise CoverageError("invalid-hud-state-assignment")
    for state in expanded:
        if assignments.get(state) != "expanded":
            raise CoverageError("invalid-hud-state-assignment")
    require_mapping(
        assignments.get("recording"),
        {"empty_preview": "compact", "non_empty_preview": "expanded"},
        "invalid-recording-preview-assignment",
    )


def validate_geometry(manifest: dict[str, Any]) -> None:
    require_mapping(
        manifest["geometry_pt"],
        {
            "popover": {"width": 340, "side_padding": 16},
            "onboarding": {"width": 640, "chrome": 38, "content_padding": [24, 32]},
            "settings": {"width": 720},
            "history": {
                "content_width": 1000,
                "content_height": 640,
                "toolbar": 44,
                "main_content": 596,
                "list_column": 340,
            },
        },
        "invalid-native-geometry",
    )
    require_mapping(
        manifest["design_tokens"],
        {"spacing_increment_pt": 4, "colors": "semantic-system-colors"},
        "invalid-design-token-contract",
    )


def validate_shortcut(manifest: dict[str, Any]) -> None:
    shortcut = manifest["shortcut"]
    if not isinstance(shortcut, dict) or set(shortcut) != {"copy_source", "conflict"}:
        raise CoverageError("unsupported-manifest-key")
    if contains_literal_shortcut(shortcut) or shortcut["copy_source"] != "committed-configuration":
        raise CoverageError("literal-shortcut")
    require_mapping(
        shortcut["conflict"],
        {
            "mouse_start_dictation": "enabled",
            "shortcut_notice": "actionable",
            "keyboard_events": "unavailable",
        },
        "conflicting-mouse-action-rule",
    )


def validate(manifest: dict[str, Any], root: Path) -> tuple[int, int, int]:
    native_surfaces = native_surfaces_from_handoff(root)
    design_files = sorted(path.name for path in (root / "design").glob("*.dc.html"))
    excluded = sorted(set(design_files) - set(native_surfaces))
    require_exact_list(manifest["native_surfaces"], native_surfaces, "missing-design-surface")
    require_exact_list(manifest["excluded_website_artifacts"], excluded, "missing-excluded-website-artifact")
    for surface in native_surfaces:
        if not (root / "design" / surface).is_file():
            raise CoverageError("missing-design-surface")
    matrix_rows = state_matrix_rows_from_document(root)
    require_exact_list(manifest["state_matrix_rows"], matrix_rows, "unassigned-state-matrix-row")
    hud_states = hud_states_from_source(root)
    validate_hud(manifest, hud_states)
    validate_geometry(manifest)
    validate_shortcut(manifest)
    return len(native_surfaces), len(hud_states), len(matrix_rows)


def main() -> int:
    try:
        manifest_path = parse_arguments()
        manifest = load_manifest(manifest_path)
        surfaces, hud_states, matrix_rows = validate(manifest, repository_root())
    except CoverageError as error:
        print(f"ERROR {error.category}", file=sys.stderr)
        return 1
    print(
        "PASS native-design-coverage "
        f"surfaces={surfaces} hud_states={hud_states} state_matrix_rows={matrix_rows} "
        "compact=224x42 expanded=280x64"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
