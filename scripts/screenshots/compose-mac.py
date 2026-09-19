#!/usr/bin/env python3
"""Frame macOS window captures as App Store screenshots.

    compose-mac.py <in-dir> <out-dir> [--size 2880x1800]

A window screenshot from XCUITest is the window alone, at the display's backing
scale, in whatever size the window happened to be. The Mac App Store accepts only
1280x800, 1440x900, 2560x1600 or 2880x1800 — so each capture is scaled to fit
inside the canvas with a margin, centred on a quiet gradient, with a soft shadow.
Nothing is added that is not in the capture; this is a frame, not a mockup.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZES = {"2880x1800", "2560x1600", "1440x900", "1280x800"}


def gradient(size, top=(24, 26, 33), bottom=(9, 10, 14)):
    w, h = size
    img = Image.new("RGB", size, top)
    px = img.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c
    return img


def frame(src: Path, dst: Path, size):
    W, H = size
    shot = Image.open(src).convert("RGBA")
    margin = round(W * 0.06)
    max_w, max_h = W - 2 * margin, H - 2 * margin
    scale = min(max_w / shot.width, max_h / shot.height, 1.0)
    if scale < 1.0:
        shot = shot.resize((round(shot.width * scale), round(shot.height * scale)), Image.LANCZOS)
    # Round the window corners the way macOS does, so the frame reads as a window.
    radius = round(12 * (shot.width / 1440))
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, shot.width - 1, shot.height - 1], radius=radius, fill=255)
    shot.putalpha(mask)

    canvas = gradient(size).convert("RGBA")
    x, y = (W - shot.width) // 2, (H - shot.height) // 2
    shadow = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [x, y + round(H * 0.012), x + shot.width, y + shot.height + round(H * 0.012)],
        radius=radius, fill=(0, 0, 0, 150),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(round(W * 0.012)))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(shot, (x, y))
    canvas.convert("RGB").save(dst, "PNG", optimize=True)


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    src, dst = Path(argv[1]), Path(argv[2])
    size = "2880x1800"
    if "--size" in argv:
        size = argv[argv.index("--size") + 1]
    if size not in SIZES:
        sys.exit(f"size must be one of {sorted(SIZES)}")
    W, H = (int(v) for v in size.split("x"))
    dst.mkdir(parents=True, exist_ok=True)
    done = 0
    for png in sorted(src.rglob("*.png")):
        out = dst / (png.stem + ".png")
        frame(png, out, (W, H))
        print(f"{png.name} -> {out} ({W}x{H})")
        done += 1
    if not done:
        sys.exit(f"no PNGs under {src}")


if __name__ == "__main__":
    main(sys.argv)
