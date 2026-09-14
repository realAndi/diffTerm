#!/usr/bin/env python3
"""Renders diffTerm's app icon.

There is no image toolchain on the device, so this draws the artwork with
plain arithmetic at 4x and box-filters it down, then writes a PNG by hand.
"""
import struct
import sys
import zlib

SS = 4  # supersampling factor


def lerp(a, b, t):
    return a + (b - a) * t


def blend(dst, src, alpha):
    return tuple(lerp(d, s, alpha) for d, s in zip(dst, src))


def hex_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


BG_TOP = hex_rgb('#1b2030')
BG_BOTTOM = hex_rgb('#0b0d14')
CHEVRON = hex_rgb('#5ac8fa')
CURSOR = hex_rgb('#f2f5fb')
GLOW = hex_rgb('#2a6fa8')


def dist_to_segment(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    length_sq = dx * dx + dy * dy
    if length_sq == 0:
        return ((px - x1) ** 2 + (py - y1) ** 2) ** 0.5
    t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / length_sq))
    nx, ny = x1 + t * dx, y1 + t * dy
    return ((px - nx) ** 2 + (py - ny) ** 2) ** 0.5


def render(size):
    n = size * SS
    # Geometry expressed in fractions of the canvas so it scales exactly.
    half = 0.5
    stroke = 0.072 * n
    cx, cy = 0.40 * n, 0.50 * n
    arm = 0.135 * n

    # Chevron: two strokes meeting at a point, like a shell prompt.
    seg_a = (cx - arm, cy - arm * 1.30, cx + arm * 0.55, cy)
    seg_b = (cx + arm * 0.55, cy, cx - arm, cy + arm * 1.30)

    # Cursor bar to the right of the prompt.
    bar_x0, bar_x1 = 0.545 * n, 0.775 * n
    bar_y = cy + arm * 1.30
    bar_h = stroke

    rows = []
    for y in range(n):
        row = []
        gy = y / (n - 1)
        base = tuple(lerp(t, b, gy) for t, b in zip(BG_TOP, BG_BOTTOM))
        for x in range(n):
            gx = x / (n - 1)
            # A soft radial lift behind the mark keeps the flat colour from
            # looking dead at large sizes.
            r = ((gx - 0.42) ** 2 + (gy - 0.46) ** 2) ** 0.5
            glow = max(0.0, 1.0 - r / 0.62) ** 2 * 0.20
            color = blend(base, GLOW, glow)

            d = min(dist_to_segment(x, y, *seg_a), dist_to_segment(x, y, *seg_b))
            cov = max(0.0, min(1.0, (stroke * half - d) / 1.0 + 0.5))
            if cov > 0:
                color = blend(color, CHEVRON, cov)

            if bar_x0 - 1 <= x <= bar_x1 + 1 and abs(y - bar_y) <= bar_h * half + 1:
                # Signed distance to the bar: negative inside, so that the
                # interior gets full coverage and only the edge is feathered.
                dx = max(bar_x0 - x, x - bar_x1)
                dy = abs(y - bar_y) - bar_h * half
                dd = max(dx, dy)
                bcov = max(0.0, min(1.0, -dd + 0.5))
                if bcov > 0:
                    color = blend(color, CURSOR, bcov)

            row.append(color)
        rows.append(row)

    # Box filter down to the requested size.
    out = bytearray()
    for y in range(size):
        out.append(0)  # PNG filter type 0
        for x in range(size):
            acc = [0.0, 0.0, 0.0]
            for sy in range(SS):
                src = rows[y * SS + sy]
                for sx in range(SS):
                    px = src[x * SS + sx]
                    acc[0] += px[0]
                    acc[1] += px[1]
                    acc[2] += px[2]
            count = SS * SS
            out += bytes(int(max(0, min(255, round(c / count)))) for c in acc)
    return bytes(out)


def write_png(path, size, raw):
    def chunk(tag, data):
        payload = tag + data
        return struct.pack('>I', len(data)) + payload + struct.pack('>I', zlib.crc32(payload) & 0xFFFFFFFF)

    header = struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0)  # 8-bit RGB
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', header)
           + chunk(b'IDAT', zlib.compress(raw, 9))
           + chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)


if __name__ == '__main__':
    out_dir = sys.argv[1]
    for name, size in [
        ('AppIcon60x60@2x.png', 120),
        ('AppIcon60x60@3x.png', 180),
        ('AppIcon76x76@2x~ipad.png', 152),
        ('AppIcon83.5x83.5@2x~ipad.png', 167),
        ('AppIcon40x40@2x.png', 80),
        ('AppIcon40x40@3x.png', 120),
        ('AppIcon29x29@2x.png', 58),
        ('AppIcon29x29@3x.png', 87),
        ('AppIcon20x20@2x.png', 40),
        ('AppIcon20x20@3x.png', 60),
        ('AppIcon1024.png', 1024),
    ]:
        write_png(f'{out_dir}/{name}', size, render(size))
        print(f'  {name} ({size}x{size})')
