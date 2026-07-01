#!/usr/bin/env python3
"""
Generates the IroncladOH app icon: a single red selection ring
(wavy inner edge, smooth outer edge, gradient alpha) on a dark background.
Outputs AppIcon.icns into the provided destination directory.

Usage: python3 gen_icon.py <dest_dir>
"""

import math
import struct
import zlib
import os
import sys
import subprocess
import shutil

# ─── Design parameters ──────────────────────────────────────────────────────
SIZE         = 1024
CENTER       = SIZE // 2

OUTER_R      = 430          # pixels — perfectly smooth outer edge
INNER_BASE_R = 295          # base inner radius before wave perturbation
FEATHER      = 2.5          # soft-edge width in pixels

# 4 harmonics: (frequency, amplitude_px, phase_radians)
# Chosen to look organic and identifiable at all icon sizes.
WAVES = [
    (2,  30.0, 0.55),
    (3,  20.0, 2.20),
    (5,  12.0, 4.10),
    (7,   7.0, 5.80),
]

# Colors
BG    = (10, 13, 26)               # very dark navy
RED   = (255, 70, 58)              # IroncladOH red selection ring
ALPHA_IN  = 0.30                   # at inner edge (matches ring 2 spec)
ALPHA_OUT = 1.00                   # at outer edge

# Subtle inner-glow: inside the wavy boundary, add a faint red haze
GLOW_WIDTH = 55                    # pixels inward from inner edge
GLOW_PEAK  = 0.12                  # max additional alpha for the glow


def inner_r(theta: float) -> float:
    r = INNER_BASE_R
    for freq, amp, phase in WAVES:
        r += amp * math.sin(freq * theta + phase)
    return r


def clamp01(v: float) -> float:
    return max(0.0, min(1.0, v))


def lerp(a, b, t):
    return a + (b - a) * t


def smoothstep(edge0, edge1, x):
    t = clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3.0 - 2.0 * t)


# ─── Rasterize 1024×1024 RGBA ───────────────────────────────────────────────
print("Rasterizing 1024×1024 icon…")
pixels = bytearray(SIZE * SIZE * 4)

for y in range(SIZE):
    dy = y - CENTER
    for x in range(SIZE):
        dx = x - CENTER
        r = math.sqrt(dx * dx + dy * dy)

        if r < 0.5:
            # Dead center — pure background
            bg_r, bg_g, bg_b = BG
            idx = (y * SIZE + x) * 4
            pixels[idx:idx+4] = bytes([bg_r, bg_g, bg_b, 255])
            continue

        theta = math.atan2(dy, dx)
        ir    = inner_r(theta)

        # ── Ring contribution ─────────────────────────────────────────────
        # Outer-edge feather: smooth from OUTER_R-FEATHER to OUTER_R+FEATHER
        outer_edge = smoothstep(OUTER_R + FEATHER, OUTER_R - FEATHER, r)
        # Inner-edge feather: smooth from ir-FEATHER to ir+FEATHER
        inner_edge = smoothstep(ir - FEATHER, ir + FEATHER, r)

        # Gradient alpha across ring width (at inner edge = ALPHA_IN, outer = ALPHA_OUT)
        t_ring = clamp01((r - ir) / max(OUTER_R - ir, 1.0))
        ring_alpha = lerp(ALPHA_IN, ALPHA_OUT, t_ring)

        ring_contrib = ring_alpha * outer_edge * inner_edge

        # ── Inner glow ────────────────────────────────────────────────────
        # Faint haze inside the wavy boundary, decaying toward center
        glow_contrib = 0.0
        if r < ir:
            dist_in = ir - r
            glow_contrib = GLOW_PEAK * smoothstep(GLOW_WIDTH, 0.0, dist_in)

        total_alpha = clamp01(ring_contrib + glow_contrib)

        # ── Composite onto background ─────────────────────────────────────
        br, bg_col, bb = BG
        cr, cg, cb = RED
        fr = int(lerp(br, cr, total_alpha) + 0.5)
        fg = int(lerp(bg_col, cg, total_alpha) + 0.5)
        fb = int(lerp(bb, cb, total_alpha) + 0.5)

        idx = (y * SIZE + x) * 4
        pixels[idx]   = fr
        pixels[idx+1] = fg
        pixels[idx+2] = fb
        pixels[idx+3] = 255   # fully opaque — background fills the non-ring regions


# ─── Write PNG ──────────────────────────────────────────────────────────────
def write_png_file(path, width, height, rgba_bytes):
    def chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)

    # Build raw scanline data (filter byte 0 = None per row)
    raw = bytearray()
    row_bytes = width * 4
    for row in range(height):
        raw += b'\x00'
        raw += rgba_bytes[row * row_bytes:(row + 1) * row_bytes]

    png  = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 6))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


tmp_png = '/tmp/ironclad_oh_icon_1024.png'
write_png_file(tmp_png, SIZE, SIZE, pixels)
print(f"Base PNG written: {tmp_png}")


# ─── Build iconset ──────────────────────────────────────────────────────────
dest_dir  = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(__file__)
iconset   = os.path.join(dest_dir, 'AppIcon.iconset')
icns_path = os.path.join(dest_dir, 'AppIcon.icns')

os.makedirs(iconset, exist_ok=True)

SIZES = [
    ('icon_16x16.png',      16),
    ('icon_16x16@2x.png',   32),
    ('icon_32x32.png',      32),
    ('icon_32x32@2x.png',   64),
    ('icon_128x128.png',   128),
    ('icon_128x128@2x.png',256),
    ('icon_256x256.png',   256),
    ('icon_256x256@2x.png',512),
    ('icon_512x512.png',   512),
    ('icon_512x512@2x.png',1024),
]

print("Scaling to all icon sizes…")
for name, px in SIZES:
    out = os.path.join(iconset, name)
    subprocess.run(['sips', '-z', str(px), str(px), tmp_png, '--out', out],
                   check=True, capture_output=True)

print("Running iconutil…")
subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', icns_path], check=True)
shutil.rmtree(iconset)
os.remove(tmp_png)

print(f"Icon written: {icns_path}")
