#!/usr/bin/env python3
"""Generate the BlueChip Rewards Android launcher icons with zero dependencies.

Draws a premium deep-blue icon with a gold diamond ("chip") and writes the full
set of legacy + adaptive mipmaps into app/android_res/, which patch_android.py
copies into the generated Android project. Re-run to regenerate.
"""
import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(__file__), "..", "android_res")

# Brand colours (RGB)
BG_TOP = (30, 58, 138)      # #1E3A8A
BG_BOT = (59, 130, 246)     # #3B82F6
GOLD = (245, 179, 1)        # #F5B301
GOLD_HI = (255, 214, 90)    # #FFD65A
GOLD_MID = (240, 165, 12)   # right facet
GOLD_LO = (214, 154, 0)     # #D69A00 bottom facet
WHITE = (255, 255, 255)


def _lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def _blend(dst, src, alpha):
    return tuple(int(round(dst[i] * (1 - alpha) + src[i] * alpha)) for i in range(3))


def _png(path, pixels, w, h):
    """pixels: list of (r,g,b,a) row-major."""
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0
        for x in range(w):
            r, g, b, a = pixels[y * w + x]
            raw += bytes((r, g, b, a))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return c + struct.pack(">I", crc)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    idat = zlib.compress(bytes(raw), 9)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


def _diamond_alpha(cx, cy, x, y, r):
    """Soft rhombus coverage in [0,1] for a diamond of 'radius' r centred at cx,cy."""
    d = (abs(x - cx) + abs(y - cy)) / r
    edge = 1.5 / r  # ~1.5px anti-alias band
    if d <= 1 - edge:
        return 1.0
    if d >= 1 + edge:
        return 0.0
    return (1 + edge - d) / (2 * edge)


def draw(size, full_bleed, diamond_scale):
    """Return an RGBA pixel list. full_bleed: paint gradient bg; else transparent."""
    px = [(0, 0, 0, 0)] * (size * size)
    cx = cy = (size - 1) / 2
    r = size * diamond_scale / 2
    for y in range(size):
        t = y / (size - 1)
        bg = _lerp(BG_TOP, BG_BOT, t)
        for x in range(size):
            if full_bleed:
                col = bg
                a = 255
            else:
                col = (0, 0, 0)
                a = 0
            cov = _diamond_alpha(cx, cy, x, y, r)
            if cov > 0:
                dx, dy = x - cx, y - cy
                # four facets meeting at the centre -> cut-gem look
                if abs(dy) >= abs(dx):
                    facet = GOLD_HI if dy < 0 else GOLD_LO   # top / bottom
                else:
                    facet = GOLD if dx < 0 else GOLD_MID     # left / right
                # brighter "table" highlight near the centre
                cd = (dx * dx + dy * dy) ** 0.5 / r
                if cd < 0.30:
                    facet = _blend(facet, GOLD_HI, (0.30 - cd) / 0.30 * 0.5)
                if full_bleed:
                    col = _blend(col, facet, cov)
                    a = 255
                else:
                    col = facet
                    a = int(round(cov * 255))
            # crisp white sparkle on the upper-left facet
            sx, sy = cx - r * 0.30, cy - r * 0.34
            sd = ((x - sx) ** 2 + (y - sy) ** 2) ** 0.5
            sr = max(1.0, size * 0.028)
            if sd < sr and (cov > 0 or full_bleed):
                sa = (1 - sd / sr) * 0.95
                col = _blend(col, WHITE, sa)
                if not full_bleed:
                    a = max(a, int(round(sa * 255)))
            px[y * size + x] = (col[0], col[1], col[2], a)
    return px


# density -> legacy launcher px size
LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
# adaptive foreground is 108dp; content kept within the ~66dp safe zone
FOREGROUND = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def main():
    for d, s in LEGACY.items():
        _png(os.path.join(OUT, f"mipmap-{d}", "ic_launcher.png"),
             draw(s, full_bleed=True, diamond_scale=0.62), s, s)
    for d, s in FOREGROUND.items():
        _png(os.path.join(OUT, f"mipmap-{d}", "ic_launcher_foreground.png"),
             draw(s, full_bleed=False, diamond_scale=0.42), s, s)

    # adaptive icon xml (v26+)
    anydpi = os.path.join(OUT, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    adaptive = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n'
    )
    with open(os.path.join(anydpi, "ic_launcher.xml"), "w") as f:
        f.write(adaptive)

    values = os.path.join(OUT, "values")
    os.makedirs(values, exist_ok=True)
    with open(os.path.join(values, "ic_launcher_background.xml"), "w") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
            '    <color name="ic_launcher_background">#1E3A8A</color>\n</resources>\n'
        )
    print("Generated launcher icons in", os.path.relpath(OUT))


if __name__ == "__main__":
    main()
