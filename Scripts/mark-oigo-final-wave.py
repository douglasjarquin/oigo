#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path


def fail(category: str) -> int:
    print(f"ERROR {category}")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--receipt-dir", required=True, type=Path)
    parser.add_argument("--frozen-plan", required=True, type=Path)
    parser.add_argument("--reviewed-plan-sha", required=True)
    args = parser.parse_args()
    try:
        if hashlib.sha256(args.frozen_plan.read_bytes()).hexdigest() != args.reviewed_plan_sha:
            return fail("frozen-plan-sha-mismatch")
        receipts = []
        for verifier in ("F1", "F2", "F3", "F4"):
            path = args.receipt_dir / verifier / "receipt.json"
            receipt = json.loads(path.read_text(encoding="utf-8"))
            if receipt.get("verdict") != "PASS":
                return fail("missing-final-verifier-pass")
            receipts.append(receipt)
        original = args.plan.read_text(encoding="utf-8")
    except (OSError, json.JSONDecodeError):
        return fail("final-verifier-receipt-missing")
    lines = original.splitlines(keepends=True)
    changed = 0
    for index, line in enumerate(lines):
        for verifier in ("F1", "F2", "F3", "F4"):
            if line.startswith(f"- [ ] {verifier}."):
                lines[index] = line.replace(f"- [ ] {verifier}.", f"- [x] {verifier}.", 1)
                changed += 1
    if changed != 4:
        return fail("final-verifier-checkbox-mismatch")
    descriptor, temporary = tempfile.mkstemp(prefix=".plan-", dir=args.plan.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write("".join(lines))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, args.plan)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"PASS final-wave plan_sha={hashlib.sha256(args.plan.read_bytes()).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
