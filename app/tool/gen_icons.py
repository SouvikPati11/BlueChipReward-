#!/usr/bin/env python3
"""Generate BlueChip Rewards Android launcher icons from the OFFICIAL logo.

Uses the exact uploaded artwork at app/assets/branding/logo.png — it does NOT
draw or approximate a logo. Produces the legacy square mipmaps and the adaptive
icon foreground for every density into app/android_res/, which patch_android.py
copies into the generated Android project. Requires Pillow (build/dev only).

Re-run after replacing the source logo:  python3 tool/gen_icons.py
"""
import os

from PIL import Image

HERE = os.path.dirname(__file__)
SRC = os.path.join(HERE, "..", "assets", "branding", "logo.png")
OUT = os.path.join(HERE, "..", "android_res")

# Adaptive-icon background: deep navy sampled from the logo's own background so
# the foreground artwork blends seamlessly under any launcher mask.
ADAPTIVE_BG = "#01143F"

# density -> legacy launcher px size (48dp base)
LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
# adaptive foreground is a 108dp canvas per density
FOREGROUND = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
# Fraction of the 108dp canvas the logo occupies. Kept modest so the whole
# mark (incl. the "REWARDS" wordmark) stays inside the launcher's safe zone and
# is not cropped by circular masks.
FG_SCALE = 0.72


def _load():
    im = Image.open(SRC).convert("RGBA")
    # square-pad if the source is ever non-square (it is 1:1 today)
    if im.width != im.height:
        s = max(im.width, im.height)
        canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        canvas.paste(im, ((s - im.width) // 2, (s - im.height) // 2), im)
        im = canvas
    return im


def _resized(im, size):
    return im.resize((size, size), Image.LANCZOS)


def _save(img, density, name):
    d = os.path.join(OUT, f"mipmap-{density}")
    os.makedirs(d, exist_ok=True)
    img.save(os.path.join(d, name))


def main():
    logo = _load()

    # Legacy square icons: the exact logo, high-quality downscaled. Its own
    # rounded-square shape + transparent corners are preserved.
    for density, size in LEGACY.items():
        icon = _resized(logo, size)
        _save(icon, density, "ic_launcher.png")
        # round variant (used by launchers that request a round icon) — the
        # same artwork; the logo already reads well within a circle.
        _save(icon, density, "ic_launcher_round.png")

    # Adaptive foreground: exact logo centred at FG_SCALE on a transparent
    # 108dp canvas so nothing important is clipped by the adaptive mask.
    for density, canvas_px in FOREGROUND.items():
        fg = Image.new("RGBA", (canvas_px, canvas_px), (0, 0, 0, 0))
        target = int(round(canvas_px * FG_SCALE))
        art = _resized(logo, target)
        off = (canvas_px - target) // 2
        fg.paste(art, (off, off), art)
        _save(fg, density, "ic_launcher_foreground.png")

    # Adaptive icon xml (v26+): solid navy background + logo foreground.
    anydpi = os.path.join(OUT, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    adaptive = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n'
    )
    for fname in ("ic_launcher.xml", "ic_launcher_round.xml"):
        with open(os.path.join(anydpi, fname), "w") as f:
            f.write(adaptive)

    values = os.path.join(OUT, "values")
    os.makedirs(values, exist_ok=True)
    with open(os.path.join(values, "ic_launcher_background.xml"), "w") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
            f'    <color name="ic_launcher_background">{ADAPTIVE_BG}</color>\n</resources>\n'
        )
    print("Generated launcher icons from official logo into", os.path.relpath(OUT))


if __name__ == "__main__":
    main()
