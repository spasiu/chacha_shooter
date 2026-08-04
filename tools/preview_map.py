#!/usr/bin/env python3
"""Draws a top-down picture of a map, for looking at without loading the game.

    python3 tools/preview_map.py [name]

Reads maps/<name>_terrain.png and maps/<name>_structures.json and writes
maps/<name>_preview.png: ground colour from the surface material, shaded by
height, with the structures drawn on top and the bases and objectives marked.

It is a cheap way to see whether a layout reads before spending several minutes
building it in the engine, which on a map this size is most of the cost of
finding out you put something in the wrong place.
"""

import json
import struct
import sys
import zlib
from pathlib import Path

MAPS = Path(__file__).resolve().parent.parent / "maps"

# Matches VoxelWorld.COLOURS closely enough to recognise the place.
GROUND_COLOURS = {
    0: (90, 110, 70), 1: (92, 133, 61), 2: (107, 79, 46), 3: (158, 158, 150),
    5: (120, 89, 54), 7: (64, 64, 66), 8: (184, 161, 112), 9: (122, 110, 97),
    10: (204, 194, 168), 11: (117, 66, 51), 12: (140, 87, 56),
    13: (158, 43, 38), 14: (46, 82, 153),
}
NAMED = {
    "grass": 1, "dirt": 2, "concrete": 3, "wood": 5, "asphalt": 7, "sand": 8,
    "stone": 9, "plaster": 10, "tile": 11, "rust": 12, "team_red": 13,
    "team_blue": 14,
}


def read_png(path):
    d = path.read_bytes()
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(d):
        ln = struct.unpack(">I", d[pos:pos + 4])[0]
        tag = d[pos + 4:pos + 8]
        if tag == b"IHDR":
            w, h = struct.unpack(">II", d[pos + 8:pos + 16])
        elif tag == b"IDAT":
            idat += d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride, rows, prev, i = w * 3, [], bytearray(w * 3), 0
    for _ in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        for x in range(stride):
            a = line[x - 3] if x >= 3 else 0
            b = prev[x]
            c = prev[x - 3] if x >= 3 else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(bytes(line)); prev = line
    return w, h, rows


def write_png(path, w, h, pix):
    raw = b"".join(b"\x00" + bytes(pix[y]) for y in range(h))
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(raw, 6))
    out += chunk(b"IEND", b"")
    path.write_bytes(out)


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "arena"
    size, _, rows = read_png(MAPS / ("%s_terrain.png" % name))
    meta = json.loads((MAPS / ("%s_structures.json" % name)).read_text())
    ground = meta.get("depth_blocks", 16)

    pix = [bytearray(size * 3) for _ in range(size)]
    for z in range(size):
        row = rows[z]
        out = pix[z]
        for x in range(size):
            h = row[x * 3]
            r, g, b = GROUND_COLOURS.get(row[x * 3 + 1], (255, 0, 255))
            # Shade by height so relief reads: the gulch walls should look like
            # walls rather than like a differently coloured floor.
            k = 0.66 + 0.5 * (h - ground) / 24.0
            k = max(0.4, min(1.45, k))
            if row[x * 3 + 2]:
                r, g, b = 40, 74, 34          # a tree
            out[x * 3] = min(255, int(r * k))
            out[x * 3 + 1] = min(255, int(g * k))
            out[x * 3 + 2] = min(255, int(b * k))

    # Structures on top, tallest last so a roof covers its own walls.
    for s in sorted(meta["structures"], key=lambda s: s.get("height", 1)):
        if s.get("clear"):
            continue
        r, g, b = GROUND_COLOURS.get(NAMED.get(s.get("type", "concrete"), 3), (200, 200, 200))
        tall = min(1.5, 0.85 + s.get("height", 1) / 26.0)
        for z in range(max(0, s["z0"]), min(size - 1, s["z1"]) + 1):
            out = pix[z]
            for x in range(max(0, s["x0"]), min(size - 1, s["x1"]) + 1):
                out[x * 3] = min(255, int(r * tall))
                out[x * 3 + 1] = min(255, int(g * tall))
                out[x * 3 + 2] = min(255, int(b * tall))

    half = size // 2
    block = meta.get("block", 0.25)

    def mark(wx, wz, colour, radius):
        cx = int(wx / block) + half
        cz = int(wz / block) + half
        for z in range(max(0, cz - radius), min(size, cz + radius)):
            for x in range(max(0, cx - radius), min(size, cx + radius)):
                d = ((x - cx) ** 2 + (z - cz) ** 2) ** 0.5
                if radius - 5 < d < radius:
                    pix[z][x * 3:x * 3 + 3] = bytes(colour)

    for side, at in meta.get("team_spawns", {}).items():
        mark(at[0], at[1], (60, 110, 255) if side == "blue" else (255, 70, 60), 26)
    for point in meta.get("capture_points", []):
        mark(point["x"], point["z"], (255, 225, 90), 30)

    out_path = MAPS / ("%s_preview.png" % name)
    write_png(out_path, size, size, pix)
    print("wrote %s  (%dx%d, north is up, east is right)" % (out_path, size, size))


if __name__ == "__main__":
    main()
