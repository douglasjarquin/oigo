#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 'usage: zsh Scripts/generate-oigo-assets.sh --output <catalog>'
    exit 64
}

if [[ $# -ne 2 || "$1" != '--output' || -z "$2" ]]; then
    usage
fi

repo_root="${0:A:h:h}"
source_artwork="$repo_root/Assets/OigoIdentity/Source/ear-o.svg"
output="$2"

if [[ ! -f "$source_artwork" ]]; then
    print -u2 'FAIL: editable ear-O source artwork is unavailable'
    exit 1
fi

if [[ -e "$output" ]]; then
    print -u2 'FAIL: output catalog already exists'
    exit 1
fi

exec /usr/bin/python3 - "$source_artwork" "$output" <<'PY'
import json
import math
import re
import shutil
import struct
import sys
import zlib
from pathlib import Path


SOURCE_VIEWBOX = (24.0, 32.0)
APP_BACKGROUND = (11, 12, 16, 255)
APP_FOREGROUND = (245, 245, 247, 255)
TEMPLATE_FOREGROUND = (0, 0, 0, 255)
APP_REPRESENTATIONS = (
    ("appicon-16.png", 16, "16x"),
    ("appicon-16@2x.png", 32, "16x 2x"),
    ("appicon-32.png", 32, "32x"),
    ("appicon-32@2x.png", 64, "32x 2x"),
    ("appicon-128.png", 128, "128x"),
    ("appicon-128@2x.png", 256, "128x 2x"),
    ("appicon-256.png", 256, "256x"),
    ("appicon-256@2x.png", 512, "256x 2x"),
    ("appicon-512.png", 512, "512x"),
    ("appicon-512@2x.png", 1024, "512x 2x"),
)


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_path(source):
    match = re.search(r'<path\b[^>]*\bid="ear-o"[^>]*\bd="([^"]+)"', source)
    if not match:
        fail("editable artwork is not the approved ear-O path")
    tokens = re.findall(r'[MC]|-?(?:\d+\.\d+|\d+)', match.group(1))
    if not tokens or tokens[0] != "M":
        fail("editable artwork is not a continuous cubic path")
    index = 1
    try:
        current = (float(tokens[index]), float(tokens[index + 1]))
        index += 2
        segments = []
        while index < len(tokens):
            if tokens[index] != "C":
                fail("editable artwork is not a continuous cubic path")
            index += 1
            values = [float(tokens[index + offset]) for offset in range(6)]
            index += 6
            control_one = (values[0], values[1])
            control_two = (values[2], values[3])
            endpoint = (values[4], values[5])
            segments.append((current, control_one, control_two, endpoint))
            current = endpoint
    except (IndexError, ValueError):
        fail("editable artwork is not a continuous cubic path")
    if len(segments) != 8:
        fail("editable artwork must contain the approved eight cubic segments")
    return segments


def cubic(segment, t):
    start, control_one, control_two, endpoint = segment
    inverse = 1.0 - t
    return (
        inverse ** 3 * start[0] + 3 * inverse ** 2 * t * control_one[0] + 3 * inverse * t ** 2 * control_two[0] + t ** 3 * endpoint[0],
        inverse ** 3 * start[1] + 3 * inverse ** 2 * t * control_one[1] + 3 * inverse * t ** 2 * control_two[1] + t ** 3 * endpoint[1],
    )


def draw_circle(pixels, width, height, center_x, center_y, radius, color):
    left = max(0, int(math.floor(center_x - radius - 1)))
    right = min(width - 1, int(math.ceil(center_x + radius + 1)))
    top = max(0, int(math.floor(center_y - radius - 1)))
    bottom = min(height - 1, int(math.ceil(center_y + radius + 1)))
    for y in range(top, bottom + 1):
        for x in range(left, right + 1):
            coverage = min(1.0, max(0.0, radius + 0.5 - math.hypot(x + 0.5 - center_x, y + 0.5 - center_y)))
            if coverage == 0.0:
                continue
            offset = (y * width + x) * 4
            alpha = int(round(coverage * color[3]))
            if alpha >= pixels[offset + 3]:
                pixels[offset:offset + 4] = bytes((color[0], color[1], color[2], alpha))


def draw_mark(pixels, width, height, segments, mark_height, foreground):
    scale = mark_height / 26.4
    offset_x = (width - 24.0 * scale) / 2.0
    offset_y = (height - 32.0 * scale) / 2.0
    samples = max(20, int(mark_height / 8.0))
    for segment in segments:
        for sample in range(samples + 1):
            x, y = cubic(segment, sample / samples)
            draw_circle(
                pixels,
                width,
                height,
                offset_x + x * scale,
                offset_y + y * scale,
                1.2 * scale,
                foreground,
            )


def app_pixels(size, segments):
    pixels = bytearray(size * size * 4)
    center = size / 2.0
    radius = size * 0.47
    for y in range(size):
        for x in range(size):
            dx = abs((x + 0.5 - center) / radius)
            dy = abs((y + 0.5 - center) / radius)
            if dx ** 5 + dy ** 5 <= 1.0:
                offset = (y * size + x) * 4
                pixels[offset:offset + 4] = bytes(APP_BACKGROUND)
    draw_mark(pixels, size, size, segments, size * 0.76, APP_FOREGROUND)
    return pixels


def menu_pixels(width, height, segments):
    pixels = bytearray(width * height * 4)
    draw_mark(pixels, width, height, segments, height * (17.0 / 22.0), TEMPLATE_FOREGROUND)
    return pixels


def png_bytes(width, height, pixels):
    rows = b"".join(b"\x00" + pixels[row * width * 4:(row + 1) * width * 4] for row in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    compressed = zlib.compressobj(level=9, method=zlib.DEFLATED, wbits=15, memLevel=9, strategy=zlib.Z_FIXED)
    payload = compressed.compress(rows) + compressed.flush()
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", payload) + chunk(b"IEND", b"")


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main():
    source_path = Path(sys.argv[1])
    output = Path(sys.argv[2])
    source = source_path.read_text(encoding="utf-8")
    if any(forbidden in source.lower() for forbidden in ("<text", "gradient", "waveform", "microphone", "sf symbol")):
        fail("editable artwork contains a forbidden substitute")
    segments = parse_path(source)
    try:
        output.mkdir(parents=False)
        write_json(output / "Contents.json", {"info": {"author": "xcode", "version": 1}})
        app_directory = output / "AppIcon.appiconset"
        app_directory.mkdir()
        app_images = []
        for filename, size, representation in APP_REPRESENTATIONS:
            (app_directory / filename).write_bytes(png_bytes(size, size, app_pixels(size, segments)))
            point_size, scale = representation.replace("x", "").split(" ")[0], "2x" if "2x" in representation else "1x"
            app_images.append({"filename": filename, "idiom": "mac", "scale": scale, "size": point_size + "x" + point_size})
        write_json(app_directory / "Contents.json", {"images": app_images, "info": {"author": "xcode", "version": 1}})
        menu_directory = output / "OigoMenuBar.imageset"
        menu_directory.mkdir()
        (menu_directory / "oigo-menubar.png").write_bytes(png_bytes(16, 22, menu_pixels(16, 22, segments)))
        (menu_directory / "oigo-menubar@2x.png").write_bytes(png_bytes(32, 44, menu_pixels(32, 44, segments)))
        write_json(menu_directory / "Contents.json", {
            "images": [
                {"filename": "oigo-menubar.png", "idiom": "mac", "scale": "1x"},
                {"filename": "oigo-menubar@2x.png", "idiom": "mac", "scale": "2x"},
            ],
            "info": {"author": "xcode", "version": 1},
            "properties": {"template-rendering-intent": "template"},
        })
    except Exception:
        if output.exists():
            shutil.rmtree(output)
        fail("asset generation did not complete")


main()
print("GREEN: generated deterministic Oigo ear-O asset catalog")
PY
