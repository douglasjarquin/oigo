#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def fail(category: str) -> int:
    print(f"ERROR {category}")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ledger", required=True, type=Path)
    parser.add_argument("--receipt-dir", required=True, type=Path)
    parser.add_argument("--lock", required=True, type=Path)
    args = parser.parse_args()
    if not args.lock.is_dir():
        return fail("missing-seal-lock")
    receipts = []
    try:
        lines = args.ledger.read_text(encoding="utf-8").splitlines()
        for verifier in ("F1", "F2", "F3", "F4"):
            receipt = json.loads((args.receipt_dir / verifier / "receipt.json").read_text(encoding="utf-8"))
            if receipt.get("verdict") != "PASS":
                return fail("missing-final-verifier-pass")
            receipts.append(receipt)
    except (OSError, json.JSONDecodeError):
        return fail("final-verifier-receipt-missing")
    existing = [json.loads(line) for line in lines if line.strip()]
    if any(str(record.get("task")) in {"F1", "F2", "F3", "F4"} for record in existing):
        return fail("duplicate-final-verifier")
    with args.ledger.open("a", encoding="utf-8") as handle:
        for receipt in receipts:
            handle.write(json.dumps(receipt, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    print("PASS final-receipts-serialized order=F1,F2,F3,F4")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
