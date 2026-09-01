#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--paths-file", required=True, type=Path)
    args = parser.parse_args()
    try:
        paths = [line.strip() for line in args.paths_file.read_text(encoding="utf-8").splitlines() if line.strip() and not line.startswith("#")]
    except OSError:
        print("ERROR paths-file-unreadable")
        return 1
    changed = [line.strip() for line in __import__("sys").stdin if line.strip()]
    forbidden = sorted(
        changed_path
        for changed_path in changed
        if any(
            changed_path == forbidden_path
            or changed_path.startswith(forbidden_path.rstrip("/") + "/")
            for forbidden_path in paths
        )
    )
    if forbidden:
        print("ERROR forbidden-scope-path")
        return 1
    print(f"PASS scope paths={len(changed)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
