#!/usr/bin/env bash
# Modified by Alauda on 2026-10-12: regenerate the neutral brand assets.
#
# Renders image/brand/assets/ from one square SVG (default: the ACP component
# icon library's acp-icon-code-quality). The committed assets are what
# image/brand/apply_brand.py writes over every upstream SonarQube mark at image
# build time; filenames follow upstream so no referencing code changes.
#
# Usage:
#   hack/apply-sonar-brand.sh [path/to/icon.svg]
#
# Requires: rsvg-convert (librsvg) and python3 (stdlib only). hack/ scripts do
# not install anything.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/image/brand/icon/acp-icon-code-quality.svg}"
OUT="$ROOT/image/brand/assets"
if [[ ! -f "$SRC" ]]; then
  echo "source svg not found: $SRC" >&2
  exit 1
fi
command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found" >&2; exit 1; }
mkdir -p "$OUT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The icon library hardcodes width/height="1024pt" on the root element; used as
# a CSS-sized image that renders only the top-left corner. Keep viewBox only.
python3 - "$SRC" "$OUT/logo.svg" <<'PY'
import re, sys
svg = open(sys.argv[1], encoding="utf-8").read()
svg = re.sub(r"<metadata>.*?</metadata>\s*", "", svg, flags=re.S)
root = re.search(r"<svg\b[^>]*>", svg)
tag = re.sub(r'\s(width|height)="[^"]*"', "", root.group(0))
if "viewBox" not in tag:
    sys.exit("source svg has no viewBox")
open(sys.argv[2], "w", encoding="utf-8").write(svg[:root.start()] + tag + svg[root.end():])
PY
echo "  wrote logo.svg"

for sz in 16 32 48; do rsvg-convert -w $sz -h $sz "$OUT/logo.svg" -o "$WORK/$sz.png"; done
rsvg-convert -w 180 -h 180 "$OUT/logo.svg" -o "$OUT/apple-touch-icon.png"
rsvg-convert -w 512 -h 512 "$OUT/logo.svg" -o "$OUT/mstile-512x512.png"
# Upstream images/sonar-logo-horizontal.png is 98x26: keep the canvas, centre a 26x26 mark.
rsvg-convert -w 26 -h 26 "$OUT/logo.svg" -o "$WORK/26.png"
python3 - "$WORK" "$OUT" <<'PY'
import struct, sys, zlib, pathlib
work, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

def read_rgba(path):
    data = path.read_bytes()
    w, h, depth, ctype = struct.unpack(">IIBB", data[16:26])
    if (depth, ctype) != (8, 6):
        sys.exit(f"{path}: expected 8-bit RGBA png")
    idat, pos = b"", 8
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        if kind == b"IDAT":
            idat += data[pos + 8:pos + 8 + n]
        pos += 12 + n
    raw, rows, prev, i = zlib.decompress(idat), [], bytearray(w * 4), 0
    for _ in range(h):
        f, line = raw[i], bytearray(raw[i + 1:i + 1 + w * 4]); i += 1 + w * 4
        for x in range(len(line)):
            a = line[x - 4] if x >= 4 else 0
            b = prev[x]
            c = prev[x - 4] if x >= 4 else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    return w, h, rows

def write_png(path, w, h, rows):
    raw = b"".join(b"\0" + bytes(r) for r in rows)
    chunk = lambda k, d: struct.pack(">I", len(d)) + k + d + struct.pack(">I", zlib.crc32(k + d))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

mw, mh, mark = read_rgba(work / "26.png")
W, H, left = 98, 26, (98 - mw) // 2
rows = [bytearray(W * 4) for _ in range(H)]
for y in range(mh):
    rows[y][left * 4:(left + mw) * 4] = mark[y]
write_png(out / "logo-horizontal.png", W, H, rows)

# favicon.ico: PNG-compressed entries, same 16/32/48 sizes upstream ships.
sizes = [16, 32, 48]
pngs = [(work / f"{s}.png").read_bytes() for s in sizes]
header = struct.pack("<HHH", 0, 1, len(sizes))
offset, entries = 6 + 16 * len(sizes), b""
for s, png in zip(sizes, pngs):
    entries += struct.pack("<BBBBHHII", s, s, 0, 0, 1, 32, len(png), offset)
    offset += len(png)
(out / "favicon.ico").write_bytes(header + entries + b"".join(pngs))
PY
echo "  wrote apple-touch-icon.png, mstile-512x512.png, logo-horizontal.png, favicon.ico"
echo "done: $OUT — commit these bytes; image builds pick them up via image/brand/apply_brand.py"
