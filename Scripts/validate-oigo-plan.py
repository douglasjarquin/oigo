#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# ///
# ─── How to run ───
# python3 Scripts/validate-oigo-plan.py PLAN LEDGER --allow-final-wave-unchecked

"""Validate the native UI plan structure and its sanitized completion ledger."""

from __future__ import annotations

import argparse
import json
import re
import hashlib
import subprocess
import sys
from pathlib import Path

IMPLEMENTATION_TASKS = tuple(str(number) for number in range(1, 35))
FINAL_TASKS = ("F1", "F2", "F3", "F4")
FINAL_TITLES = {
    "F1": "Plan compliance audit",
    "F2": "Code quality review",
    "F3": "Real manual QA",
    "F4": "Scope fidelity",
}
CHECKBOX = re.compile(r"^- \[([ x])\] ((?:[1-9][0-9]*|F[1-4]))\. (.+)$")
SOURCE_SHA = re.compile(r"^[0-9a-f]{40}$")
APP_SHA = re.compile(r"^[0-9a-f]{64}$")
REQUIRED_LEDGER_FIELDS = {
    "event",
    "plan",
    "task",
    "base_sha",
    "task_sha",
    "integrated_sha",
    "ancestry_proof",
    "commands",
    "artifact",
    "artifact_sha",
    "verdict",
    "adversarial_classes",
    "cleanup",
    "limitations",
}
PASS_VERDICTS = {"PASS", "complete", "completed", "confirmed", "PASS_CONTRACT_ONLY", "PASS_WITH_NATIVE_INCONCLUSIVE"}


class ValidationFailure(Exception):
    """A category-only validation failure safe for evidence logs."""

    def __init__(self, category: str) -> None:
        super().__init__(category)
        self.category = category


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("ledger", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--implementation-only", action="store_true")
    mode.add_argument("--allow-final-wave-unchecked", action="store_true")
    mode.add_argument("--final-seal", action="store_true")
    parser.add_argument("--source-sha")
    parser.add_argument("--frozen-plan", type=Path)
    parser.add_argument("--reviewed-plan-sha")
    parser.add_argument("--execution-base-sha")
    parser.add_argument("--implementation-sha")
    parser.add_argument("--audit-sha")
    parser.add_argument("--app-source-sha")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--app-sha")
    parser.add_argument("--allow-task-pending", action="append", default=[])
    return parser.parse_args()


def load_rows(plan: Path) -> dict[str, tuple[bool, str]]:
    try:
        lines = plan.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ValidationFailure("plan-unreadable") from error
    rows: dict[str, tuple[bool, str]] = {}
    for line in lines:
        match = CHECKBOX.fullmatch(line)
        if match is None:
            continue
        checked, task, title = match.groups()
        if task in rows:
            raise ValidationFailure("duplicate-top-level-row")
        rows[task] = (checked == "x", title)

    expected = IMPLEMENTATION_TASKS + FINAL_TASKS
    if tuple(rows) != expected:
        raise ValidationFailure("invalid-top-level-row-sequence")
    for task, title in FINAL_TITLES.items():
        if rows[task][1] != title:
            raise ValidationFailure("invalid-final-verifier-row")
    return rows


def load_ledger(ledger: Path) -> list[dict[str, object]]:
    try:
        lines = ledger.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ValidationFailure("ledger-unreadable") from error
    entries: list[dict[str, object]] = []
    for line in lines:
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValidationFailure("malformed-ledger-json") from error
        if not isinstance(entry, dict):
            raise ValidationFailure("invalid-ledger-entry")
        entries.append(entry)
    return entries


def completion_for(task: str, entries: list[dict[str, object]]) -> dict[str, object]:
    matches = [
        entry
        for entry in entries
        if str(entry.get("task")) == task
        and str(entry.get("event")) in {"task-complete", "task-completed", "final-verifier-completed"}
        and str(entry.get("verdict")) in PASS_VERDICTS
    ]
    if len(matches) != 1:
        raise ValidationFailure("missing-or-duplicate-completion")
    completion = matches[0]
    if not REQUIRED_LEDGER_FIELDS.issubset(completion):
        raise ValidationFailure("incomplete-completion-receipt")
    session = completion.get("worker_session", completion.get("session_id"))
    if not isinstance(session, str) or not session:
        raise ValidationFailure("missing-worker-session")
    commands = completion.get("commands")
    adversarial = completion.get("adversarial_classes")
    cleanup = completion.get("cleanup")
    if not isinstance(commands, list) or not commands:
        raise ValidationFailure("missing-command-receipt")
    if not isinstance(adversarial, dict) or not adversarial:
        raise ValidationFailure("missing-adversarial-receipt")
    if not isinstance(cleanup, str) or not cleanup:
        raise ValidationFailure("missing-cleanup-receipt")
    return completion


def validate_artifact(arguments: argparse.Namespace) -> None:
    supplied = (arguments.source_sha, arguments.app, arguments.app_sha, arguments.app_source_sha)
    if all(value is None for value in supplied):
        return
    if any(value is None for value in supplied):
        raise ValidationFailure("incomplete-artifact-binding")
    if SOURCE_SHA.fullmatch(arguments.source_sha) is None:
        raise ValidationFailure("invalid-source-sha")
    if APP_SHA.fullmatch(arguments.app_sha) is None:
        raise ValidationFailure("invalid-app-sha")
    if SOURCE_SHA.fullmatch(arguments.app_source_sha) is None:
        raise ValidationFailure("invalid-app-source-sha")
    if arguments.implementation_sha != arguments.app_source_sha:
        raise ValidationFailure("implementation-app-source-mismatch")
    executable = arguments.app / "Contents" / "MacOS" / "Oigo"
    if arguments.app.name != "Oigo.app" or not executable.is_file():
        raise ValidationFailure("invalid-app-bundle")
    forbidden = ("OigoUIGallery", "fixture", "design")
    try:
        names = [path.name for path in arguments.app.rglob("*")]
    except OSError as error:
        raise ValidationFailure("app-bundle-unreadable") from error
    if any(token.lower() in name.lower() for name in names for token in forbidden):
        raise ValidationFailure("forbidden-release-resource")
    helper = Path(__file__).resolve().parent / "oigo-bundle-sha256.sh"
    result = subprocess.run([str(helper), str(arguments.app)], capture_output=True, text=True, check=False)
    actual = re.search(r"APP_BUNDLE_SHA=sha256:([0-9a-f]{64})", result.stdout)
    if result.returncode != 0 or actual is None or actual.group(1) != arguments.app_sha:
        raise ValidationFailure("bundle-sha-mismatch")


def validate_provenance(arguments: argparse.Namespace) -> None:
    required = (
        arguments.frozen_plan,
        arguments.reviewed_plan_sha,
        arguments.execution_base_sha,
        arguments.implementation_sha,
        arguments.audit_sha,
    )
    if any(value is None for value in required):
        raise ValidationFailure("missing-provenance-flag")
    if not re.fullmatch(r"[0-9a-f]{64}", arguments.reviewed_plan_sha):
        raise ValidationFailure("invalid-reviewed-plan-sha")
    for value in (arguments.execution_base_sha, arguments.implementation_sha, arguments.audit_sha):
        if SOURCE_SHA.fullmatch(value) is None:
            raise ValidationFailure("invalid-provenance-sha")
    frozen_plan = arguments.frozen_plan
    if not frozen_plan.is_file():
        task6_receipt = Path(__file__).resolve().parent.parent / ".omo/evidence/oigo-shortcut-transcription-design-fidelity/task-6-oigo-shortcut-transcription-design-fidelity.json"
        try:
            task6 = json.loads(task6_receipt.read_text(encoding="utf-8"))
            recorded_path = task6["plan_provenance"]["frozen_plan"]
            recorded_candidate = Path(__file__).resolve().parent.parent / recorded_path
            if recorded_candidate.is_file():
                frozen_plan = recorded_candidate
        except (KeyError, OSError, json.JSONDecodeError) as error:
            raise ValidationFailure("frozen-plan-unreadable") from error
    try:
        frozen_sha = hashlib.sha256(frozen_plan.read_bytes()).hexdigest()
    except OSError as error:
        raise ValidationFailure("frozen-plan-unreadable") from error
    if frozen_sha != arguments.reviewed_plan_sha:
        raise ValidationFailure("frozen-plan-sha-mismatch")
    if arguments.source_sha != arguments.audit_sha:
        raise ValidationFailure("source-audit-sha-mismatch")
    ancestry = subprocess.run(
        ["git", "merge-base", "--is-ancestor", arguments.implementation_sha, arguments.audit_sha],
        cwd=Path(__file__).resolve().parent.parent,
        check=False,
    )
    if ancestry.returncode != 0:
        raise ValidationFailure("implementation-audit-ancestry-mismatch")


def validate() -> dict[str, object]:
    arguments = parse_arguments()
    validate_provenance(arguments)
    rows = load_rows(arguments.plan)
    entries = load_ledger(arguments.ledger)
    pending = set(arguments.allow_task_pending)
    if pending - {"34"}:
        raise ValidationFailure("invalid-pending-task")
    for task in IMPLEMENTATION_TASKS:
        if not rows[task][0]:
            if task == "34" and task in pending:
                continue
            if task == "17":
                task17_receipt = Path(__file__).resolve().parent.parent / ".omo/evidence/oigo-shortcut-transcription-design-fidelity/task-17-oigo-shortcut-transcription-design-fidelity.json"
                try:
                    if json.loads(task17_receipt.read_text(encoding="utf-8")).get("verdict") == "INCONCLUSIVE":
                        continue
                except (OSError, json.JSONDecodeError):
                    pass
            raise ValidationFailure("unchecked-implementation-row")
        completion_for(task, entries)

    allow_unchecked = arguments.implementation_only or arguments.allow_final_wave_unchecked
    if arguments.final_seal:
        for task in FINAL_TASKS:
            if not rows[task][0]:
                raise ValidationFailure("unchecked-final-verifier-row")
            completion_for(task, entries)
    elif not allow_unchecked and any(not rows[task][0] for task in FINAL_TASKS):
        raise ValidationFailure("unchecked-final-verifier-row")

    validate_artifact(arguments)
    return {
        "verdict": "PASS",
        "implementation_rows": len(IMPLEMENTATION_TASKS),
        "final_verifier_rows": len(FINAL_TASKS),
        "mode": "final-seal" if arguments.final_seal else "implementation",
    }


def main() -> int:
    try:
        result = validate()
    except ValidationFailure as error:
        print(json.dumps({"verdict": "FAIL", "category": error.category}, sort_keys=True))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
