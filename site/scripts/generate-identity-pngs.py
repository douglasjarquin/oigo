#!/usr/bin/env python3
"""Rasterize site favicon, apple-touch-icon, and og:image from the ear-O source.

The SVG is generation input only. Output PNGs are the site runtime resources.
"""

from __future__ import annotations

import math
import re
import struct
import sys
import zlib
from pathlib import Path

SITE_ROOT = Path(__file__).resolve().parent.parent
REPO_ROOT = SITE_ROOT.parent
SOURCE = REPO_ROOT / "Assets" / "OigoIdentity" / "Source" / "ear-o.svg"
PUBLIC = SITE_ROOT / "public"

APP_BACKGROUND = (11, 12, 16, 255)
APP_FOREGROUND = (245, 245, 247, 255)
PAGE_BACKGROUND = (10, 10, 12, 255)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_path(source: str) -> list[tuple[tuple[float, float], tuple[float, float], tuple[float, float], tuple[float, float]]]:
    match = re.search(r'<path\b[^>]*\bid="ear-o"[^>]*\bd="([^"]+)"', source)
    if not match:
        fail("editable artwork is not the approved ear-O path")
    tokens = re.findall(r"[MC]|-?(?:\d+\.\d+|\d+)", match.group(1))
    if not tokens or tokens[0] != "M":
        fail("editable artwork is not a continuous cubic path")
    index = 1
    try:
        current = (float(tokens[index]), float(tokens[index + 1]))
        index += 2
        segments: list[tuple[tuple[float, float], tuple[float, float], tuple[float, float], tuple[float, float]]] = []
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


def cubic(
    segment: tuple[tuple[float, float], tuple[float, float], tuple[float, float], tuple[float, float]],
    t: float,
) -> tuple[float, float]:
    start, control_one, control_two, endpoint = segment
    inverse = 1.0 - t
    return (
        inverse**3 * start[0]
        + 3 * inverse**2 * t * control_one[0]
        + 3 * inverse * t**2 * control_two[0]
        + t**3 * endpoint[0],
        inverse**3 * start[1]
        + 3 * inverse**2 * t * control_one[1]
        + 3 * inverse * t**2 * control_two[1]
        + t**3 * endpoint[1],
    )


def draw_circle(
    pixels: bytearray,
    width: int,
    height: int,
    center_x: float,
    center_y: float,
    radius: float,
    color: tuple[int, int, int, int],
) -> None:
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
                pixels[offset : offset + 4] = bytes((color[0], color[1], color[2], alpha))


def draw_mark(
    pixels: bytearray,
    width: int,
    height: int,
    segments: list[tuple[tuple[float, float], tuple[float, float], tuple[float, float], tuple[float, float]]],
    mark_height: float,
    foreground: tuple[int, int, int, int],
) -> None:
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


def fill_pixels(width: int, height: int, color: tuple[int, int, int, int]) -> bytearray:
    return bytearray(bytes(color) * (width * height))


def squircle_icon(size: int, segments: list[tuple[tuple[float, float], tuple[float, float], tuple[float, float], tuple[float, float]]]) -> bytearray:
    pixels = bytearray(size * size * 4)
    center = size / 2.0
    radius = size * 0.47
    background = bytes(APP_BACKGROUND)
    for y in range(size):
        for x in range(size):
            dx = abs((x + 0.5 - center) / radius)
            dy = abs((y + 0.5 - center) / radius)
            if dx**5 + dy**5 <= 1.0:
                offset = (y * size + x) * 4
                pixels[offset : offset + 4] = background
    draw_mark(pixels, size, size, segments, size * 0.76, APP_FOREGROUND)
    return pixels


def square_icon(size: int, segments: list[tuple[tuple[float, float], tuple[float, float], tuple[float, float], tuple[float, float]]]) -> bytearray:
    pixels = fill_pixels(size, size, APP_BACKGROUND)
    draw_mark(pixels, size, size, segments, size * 0.76, APP_FOREGROUND)
    return pixels


def blit(
    dest: bytearray,
    dest_width: int,
    dest_height: int,
    source: bytearray,
    source_size: int,
    origin_x: int,
    origin_y: int,
) -> None:
    for y in range(source_size):
        dest_y = origin_y + y
        if dest_y < 0 or dest_y >= dest_height:
            continue
        for x in range(source_size):
            dest_x = origin_x + x
            if dest_x < 0 or dest_x >= dest_width:
                continue
            src_offset = (y * source_size + x) * 4
            alpha = source[src_offset + 3]
            if alpha == 0:
                continue
            dest_offset = (dest_y * dest_width + dest_x) * 4
            dest[dest_offset : dest_offset + 4] = source[src_offset : src_offset + 4]


def png_bytes(width: int, height: int, pixels: bytearray) -> bytes:
    rows = b"".join(b"\x00" + pixels[row * width * 4 : (row + 1) * width * 4] for row in range(height))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    compressed = zlib.compressobj(level=9, method=zlib.DEFLATED, wbits=15, memLevel=9, strategy=zlib.Z_FIXED)
    payload = compressed.compress(rows) + compressed.flush()
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", payload)
        + chunk(b"IEND", b"")
    )


def main() -> None:
    if not SOURCE.is_file():
        fail("editable ear-O source artwork is unavailable")
    source = SOURCE.read_text(encoding="utf-8")
    if any(forbidden in source.lower() for forbidden in ("<text", "gradient", "waveform", "microphone", "sf symbol")):
        fail("editable artwork contains a forbidden substitute")
    segments = parse_path(source)
    PUBLIC.mkdir(parents=True, exist_ok=True)

    (PUBLIC / "favicon.png").write_bytes(png_bytes(32, 32, square_icon(32, segments)))
    (PUBLIC / "apple-touch-icon.png").write_bytes(png_bytes(180, 180, square_icon(180, segments)))

    og_width, og_height, icon_size = 1200, 630, 512
    og_pixels = fill_pixels(og_width, og_height, PAGE_BACKGROUND)
    icon = squircle_icon(icon_size, segments)
    blit(
        og_pixels,
        og_width,
        og_height,
        icon,
        icon_size,
        (og_width - icon_size) // 2,
        (og_height - icon_size) // 2,
    )
    (PUBLIC / "og.png").write_bytes(png_bytes(og_width, og_height, og_pixels))
    print("GREEN: generated site identity PNGs")


if __name__ == "__main__":
    main()
