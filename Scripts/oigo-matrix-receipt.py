#!/usr/bin/env python3
import argparse
import hashlib
import json
import struct
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png_bounds(data: bytes):
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    return {"width": struct.unpack(">I", data[16:20])[0], "height": struct.unpack(">I", data[20:24])[0]}


def collect_accessibility(value, found):
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if "accessibility" in lowered or lowered.endswith("identifier") or lowered.endswith("identifiers"):
                collect_strings(child, found)
            collect_accessibility(child, found)
    elif isinstance(value, list):
        for child in value:
            collect_accessibility(child, found)


def collect_strings(value, found):
    if isinstance(value, str) and value:
        found.add(value)
    elif isinstance(value, list):
        for child in value:
            collect_strings(child, found)


def artifact(path: Path, root: Path):
    data = path.read_bytes()
    return {
        "path": str(path.relative_to(root)),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def write_row(args):
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    screenshots = []
    accessibility = set()
    for path in sorted(root.rglob("*.png")):
        data = path.read_bytes()
        bounds = png_bounds(data)
        if bounds is None:
            raise SystemExit(f"invalid-png:{path}")
        screenshots.append({**artifact(path, root), "bounds": bounds})
    for path in sorted(root.rglob("*.json")):
        if path.name in {"screenshot-receipt.json", "matrix-manifest.json", "matrix-receipt.json"}:
            continue
        try:
            collect_accessibility(json.loads(path.read_text()), accessibility)
        except (OSError, json.JSONDecodeError):
            continue
    receipt = {
        "schema": "oigo-matrix-screenshot-receipt-v1",
        "sourceSHA": args.source_sha,
        "integratedSHA": args.integrated_sha,
        "scenario": args.scenario,
        "appearance": args.appearance,
        "contrast": args.contrast,
        "pixelTolerance": 0.01,
        "accessibilityIdentifiers": sorted(accessibility),
        "bounds": [item["bounds"] for item in screenshots],
        "screenshots": screenshots,
        "screenshotCount": len(screenshots),
    }
    (root / "screenshot-receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    write_manifest(root, "matrix-manifest.json", args.source_sha, args.integrated_sha)


def write_manifest(root: Path, name: str, source_sha: str, integrated_sha: str):
    path = root / name
    artifacts = [artifact(item, root) for item in sorted(root.rglob("*")) if item.is_file() and item != path]
    manifest = {
        "schema": "oigo-matrix-manifest-v1",
        "sourceSHA": source_sha,
        "integratedSHA": integrated_sha,
        "artifactCount": len(artifacts),
        "artifacts": artifacts,
    }
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def aggregate(args):
    root = args.root.resolve()
    rows = []
    for path in sorted(root.rglob("screenshot-receipt.json")):
        row = json.loads(path.read_text())
        rows.append({"path": str(path.relative_to(root)), "receipt": row})
    receipt = {
        "schema": "oigo-matrix-receipt-v1",
        "sourceSHA": args.source_sha,
        "integratedSHA": args.integrated_sha,
        "appearance": args.appearance,
        "contrast": args.contrast,
        "rowCount": len(rows),
        "rows": rows,
    }
    (root / "matrix-receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    write_manifest(root, "matrix-manifest.json", args.source_sha, args.integrated_sha)


parser = argparse.ArgumentParser()
parser.add_argument("--root", required=True, type=Path)
parser.add_argument("--source-sha", required=True)
parser.add_argument("--integrated-sha", required=True)
parser.add_argument("--scenario")
parser.add_argument("--appearance", required=True)
parser.add_argument("--contrast", required=True)
parser.add_argument("--aggregate", action="store_true")
parsed = parser.parse_args()
if parsed.aggregate:
    aggregate(parsed)
else:
    if not parsed.scenario:
        parser.error("--scenario is required unless --aggregate is used")
    write_row(parsed)
