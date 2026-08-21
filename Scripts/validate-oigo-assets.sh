#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 'usage: zsh Scripts/validate-oigo-assets.sh <catalog> [--require-clean-worktree]'
    exit 64
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
fi

catalog="$1"
require_clean=0
if [[ $# -eq 2 ]]; then
    if [[ "$2" != '--require-clean-worktree' ]]; then
        usage
    fi
    require_clean=1
fi

repo_root="${0:A:h:h}"
source_artwork="$repo_root/Assets/OigoIdentity/Source/ear-o.svg"
generator="$repo_root/Scripts/generate-oigo-assets.sh"

if [[ ! -d "$catalog" || ! -f "$source_artwork" || ! -f "$generator" ]]; then
    print -u2 'FAIL: required asset validation input is unavailable'
    exit 1
fi

if (( require_clean )) && [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
    print -u2 'FAIL: worktree has uncommitted changes'
    exit 1
fi

if ! /usr/bin/python3 - "$catalog" "$source_artwork" <<'PY'
import json
import re
import struct
import sys
from pathlib import Path


catalog = Path(sys.argv[1])
source = Path(sys.argv[2]).read_text(encoding="utf-8")


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        fail("malformed asset metadata")


def png_dimensions(path):
    try:
        data = path.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
            fail("invalid PNG representation")
        return struct.unpack(">II", data[16:24])
    except OSError:
        fail("invalid PNG representation")


if any(forbidden in source.lower() for forbidden in ("<text", "gradient", "waveform", "microphone", "sf symbol")):
    fail("editable artwork contains a forbidden substitute")
path_match = re.search(r'<path\b[^>]*\bid="ear-o"[^>]*\bd="([^"]+)"', source)
if not path_match or len(re.findall(r'\bC', path_match.group(1))) != 8 or "Z" in path_match.group(1):
    fail("editable artwork is not the approved continuous ear-O stroke")

expected = {
    "AppIcon.appiconset/appicon-16.png": (16, 16, "AppIcon 16pt 1x"),
    "AppIcon.appiconset/appicon-16@2x.png": (32, 32, "AppIcon 16pt 2x"),
    "AppIcon.appiconset/appicon-32.png": (32, 32, "AppIcon 32pt 1x"),
    "AppIcon.appiconset/appicon-32@2x.png": (64, 64, "AppIcon 32pt 2x"),
    "AppIcon.appiconset/appicon-128.png": (128, 128, "AppIcon 128pt 1x"),
    "AppIcon.appiconset/appicon-128@2x.png": (256, 256, "AppIcon 128pt 2x"),
    "AppIcon.appiconset/appicon-256.png": (256, 256, "AppIcon 256pt 1x"),
    "AppIcon.appiconset/appicon-256@2x.png": (512, 512, "AppIcon 256pt 2x"),
    "AppIcon.appiconset/appicon-512.png": (512, 512, "AppIcon 512pt 1x"),
    "AppIcon.appiconset/appicon-512@2x.png": (1024, 1024, "AppIcon 512pt 2x"),
    "OigoMenuBar.imageset/oigo-menubar.png": (16, 22, "menu-bar 1x"),
    "OigoMenuBar.imageset/oigo-menubar@2x.png": (32, 44, "menu-bar 2x"),
}
expected_app_icon_tuples = {
    ("appicon-16.png", "mac", "16x16", "1x"),
    ("appicon-16@2x.png", "mac", "16x16", "2x"),
    ("appicon-32.png", "mac", "32x32", "1x"),
    ("appicon-32@2x.png", "mac", "32x32", "2x"),
    ("appicon-128.png", "mac", "128x128", "1x"),
    ("appicon-128@2x.png", "mac", "128x128", "2x"),
    ("appicon-256.png", "mac", "256x256", "1x"),
    ("appicon-256@2x.png", "mac", "256x256", "2x"),
    ("appicon-512.png", "mac", "512x512", "1x"),
    ("appicon-512@2x.png", "mac", "512x512", "2x"),
}
for relative, (width, height, representation) in expected.items():
    asset = catalog / relative
    if not asset.is_file():
        fail(f"missing representation: {representation}")
    if png_dimensions(asset) != (width, height):
        fail(f"incorrect dimensions: {representation}")

root_metadata = read_json(catalog / "Contents.json")
app_metadata = read_json(catalog / "AppIcon.appiconset" / "Contents.json")
menu_metadata = read_json(catalog / "OigoMenuBar.imageset" / "Contents.json")
if root_metadata != {"info": {"author": "xcode", "version": 1}}:
    fail("malformed asset metadata")
app_images = app_metadata.get("images")
if not isinstance(app_images, list) or app_metadata.get("info") != {"author": "xcode", "version": 1}:
    fail("malformed asset metadata")
try:
    actual_app_icon_tuples = {
        (image["filename"], image["idiom"], image["size"], image["scale"])
        for image in app_images
        if isinstance(image, dict) and set(image) == {"filename", "idiom", "size", "scale"}
    }
except (KeyError, TypeError):
    fail("malformed asset metadata")
if len(app_images) != len(expected_app_icon_tuples) or len(actual_app_icon_tuples) != len(app_images):
    fail("malformed AppIcon metadata")
missing_app_icon_tuples = expected_app_icon_tuples - actual_app_icon_tuples
if missing_app_icon_tuples:
    _, _, size, scale = sorted(missing_app_icon_tuples)[0]
    fail(f"missing AppIcon tuple: {size.split('x')[0]}pt {scale}")
if actual_app_icon_tuples != expected_app_icon_tuples:
    fail("unexpected AppIcon tuple")
if menu_metadata.get("properties", {}).get("template-rendering-intent") != "template":
    fail("menu-bar asset is not declared as a template")

actual = {path.relative_to(catalog).as_posix() for path in catalog.rglob("*") if path.is_file()}
expected_files = set(expected) | {"Contents.json", "AppIcon.appiconset/Contents.json", "OigoMenuBar.imageset/Contents.json"}
if actual != expected_files:
    fail("catalog has unexpected production resources")
PY
then
    exit 1
fi

comparison_root=$(mktemp -d -t oigo-asset-validation)
trap 'rm -rf "$comparison_root"' EXIT
if ! zsh "$generator" --output "$comparison_root/Assets.xcassets" >/dev/null 2>&1; then
    print -u2 'FAIL: deterministic comparison generation failed'
    exit 1
fi
if ! diff -qr "$catalog" "$comparison_root/Assets.xcassets" >/dev/null; then
    print -u2 'FAIL: catalog does not match deterministic source generation'
    exit 1
fi

print 'GREEN: required app-icon and menu-bar representations are deterministic and valid'
