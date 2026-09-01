#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

ROW = re.compile(r"^- \[([ x])\] ((?:[1-9][0-9]*|F[1-4]))\. (.+)$")


def main() -> int:
    if len(sys.argv) != 2:
        print("ERROR invalid-arguments", file=sys.stderr)
        return 1
    plan = Path(sys.argv[1])
    try:
        rows = [ROW.fullmatch(line) for line in plan.read_text(encoding="utf-8").splitlines()]
    except OSError:
        print("ERROR plan-unreadable", file=sys.stderr)
        return 1
    parsed = [match.groups() for match in rows if match]
    expected = [str(number) for number in range(1, 35)] + ["F1", "F2", "F3", "F4"]
    if [row[1] for row in parsed] != expected:
        print("ERROR invalid-top-level-row-sequence", file=sys.stderr)
        return 1
    if sum(row[1] == "17" for row in parsed) != 1 or sum(row[1] == "34" for row in parsed) != 1:
        print("ERROR duplicate-required-task", file=sys.stderr)
        return 1
    print(f"PASS plan-structure tasks=34 final-verifiers=4 task17={next(row[0] for row in parsed if row[1] == '17')} task34={next(row[0] for row in parsed if row[1] == '34')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
