# The app icon (Backyard/Assets.xcassets/AppIcon.appiconset): a round songbird on a
# branch, drawn by hand, light and dark. Run: uv run --with pillow python icon.py <folder>
import sys
from PIL import Image, ImageDraw
K = 4; N = 1024 * K
def hexc(h): return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
def icon(top, bottom, bird, wing, eye, branch, out):
    im = Image.new("RGB", (N, N))
    d = ImageDraw.Draw(im)
    a, b = hexc(top), hexc(bottom)
    for y in range(N):
        t = y / N
        d.line([(0, y), (N, y)], fill=tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3)))
    s = lambda *p: [v * K for v in p]
    # the branch
    d.line(s(150, 760, 880, 700), fill=hexc(branch), width=34 * K)
    d.ellipse(s(862, 683, 898, 719), fill=hexc(branch)); d.ellipse(s(132, 743, 168, 779), fill=hexc(branch))
    # the tail, the body, the head
    d.polygon(s(330, 560, 140, 470, 120, 520, 300, 660), fill=hexc(bird))
    d.ellipse(s(270, 380, 700, 730), fill=hexc(bird))
    d.ellipse(s(520, 250, 790, 520), fill=hexc(bird))
    # the beak, the wing, the eye
    d.polygon(s(775, 360, 880, 395, 775, 425), fill=hexc(bird))
    d.ellipse(s(320, 470, 610, 630), fill=hexc(wing))
    d.ellipse(s(668, 338, 708, 378), fill=hexc(eye))
    # legs onto the branch
    for x in (470, 540):
        d.line(s(x, 715, x - 6, 742), fill=hexc(branch), width=14 * K)
    im.resize((1024, 1024), Image.LANCZOS).save(out)
icon("5A7D47", "3F5C30", "F0EFE7", "D9D8CB", "3F5C30", "2E4423", sys.argv[1] + "/icon.png")
icon("1C1F1A", "10120F", "9DBE84", "86A86E", "10120F", "3A4433", sys.argv[1] + "/icon-dark.png")
