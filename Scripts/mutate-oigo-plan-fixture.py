#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path


def fail(category: str) -> int:
    print(f"ERROR {category}")
    return 1


def safe_path(path: Path, root: Path) -> bool:
    try:
        resolved = path.resolve(strict=False)
        root_resolved = root.resolve(strict=True)
    except OSError:
        return False
    if any(part.is_symlink() for part in [root, *root.parents] if part.exists()):
        return False
    current = root_resolved
    if not resolved.is_relative_to(current):
        return False
    relative = resolved.relative_to(current)
    for part in relative.parts[:-1]:
        current /= part
        if current.is_symlink():
            return False
    return True


def atomic_write(path: Path, content: str) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".fixture-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--mode", required=True, choices=("drop-task-completion", "replace-task-sha", "replace-integrated-sha", "duplicate-substantive-completion", "forge-task17-pass", "uncheck-task"))
    parser.add_argument("--task", required=True)
    parser.add_argument("--sha")
    args = parser.parse_args()
    root = args.input.parent
    if args.input.parent.resolve() != args.output.parent.resolve():
        return fail("fixture-root-mismatch")
    if not safe_path(args.input, root) or not safe_path(args.output, root) or args.input.is_symlink() or args.output.is_symlink():
        return fail("symlink-path")
    try:
        text = args.input.read_text(encoding="utf-8")
    except OSError:
        return fail("input-unreadable")
    if args.mode == "uncheck-task":
        marker = f"- [x] {args.task}."
        count = text.count(marker)
        if count != 1:
            return fail("expected-record-missing-or-duplicate")
        atomic_write(args.output, text.replace(marker, f"- [ ] {args.task}.", 1))
        print("PASS mutated-fixture")
        return 0
    try:
        records = [json.loads(line) for line in text.splitlines() if line.strip()]
    except json.JSONDecodeError:
        return fail("malformed-ledger")
    matches = [index for index, record in enumerate(records) if str(record.get("task")) == args.task and str(record.get("event")) in {"task-complete", "task-completed", "final-verifier-completed"}]
    if len(matches) != 1:
        return fail("expected-record-missing-or-duplicate")
    index = matches[0]
    if args.mode == "drop-task-completion":
        records.pop(index)
    elif args.mode in {"replace-task-sha", "replace-integrated-sha"}:
        if args.sha is None or len(args.sha) != 40 or any(character not in "0123456789abcdef" for character in args.sha):
            return fail("invalid-sha")
        records[index]["task_sha" if args.mode == "replace-task-sha" else "integrated_sha"] = args.sha
    elif args.mode == "duplicate-substantive-completion":
        records.append(dict(records[index]))
    else:
        template = dict(records[index])
        template["task"] = "17"
        template["verdict"] = "PASS"
        records.append(template)
    atomic_write(args.output, "".join(json.dumps(record, sort_keys=True) + "\n" for record in records))
    print("PASS mutated-fixture")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
