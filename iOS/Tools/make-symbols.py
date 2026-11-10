#!/usr/bin/env python3
"""Draws the app's own symbols (for the Control Center controls and the app) as SF Symbol templates.

    python3 iOS/Tools/make-symbols.py        # writes iOS/Shared/Symbols.xcassets

Each symbol is built from filled outlines only, which is what symbol templates allow. Coordinates are in the
template's units at 100 pt, relative to the baseline, y pointing down: the cap height is 70.459 above it.
"""
import json, math, os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Shared", "Symbols.xcassets")
CX, CY = 60.0, -35.0   # the middle of a symbol
STROKE = 7.5


class Path:
    def __init__(self):
        self.d = []

    def move(self, x, y):
        self.d.append(f"M{x:.3f} {y:.3f}")

    def line(self, x, y):
        self.d.append(f"L{x:.3f} {y:.3f}")

    def close(self):
        self.d.append("Z")

    def arc(self, cx, cy, r, a0, a1, start=False):
        """An arc as cubic curves, from angle a0 to a1 (radians, either direction)."""
        pieces = max(1, math.ceil(abs(a1 - a0) / (math.pi / 2) - 1e-9))
        step = (a1 - a0) / pieces
        k = 4 / 3 * math.tan(step / 4)
        x0, y0 = cx + r * math.cos(a0), cy + r * math.sin(a0)
        (self.move if start else self.line)(x0, y0)
        for i in range(pieces):
            a, b = a0 + i * step, a0 + (i + 1) * step
            c1 = (cx + r * (math.cos(a) - k * math.sin(a)), cy + r * (math.sin(a) + k * math.cos(a)))
            c2 = (cx + r * (math.cos(b) + k * math.sin(b)), cy + r * (math.sin(b) - k * math.cos(b)))
            end = (cx + r * math.cos(b), cy + r * math.sin(b))
            self.d.append(f"C{c1[0]:.3f} {c1[1]:.3f} {c2[0]:.3f} {c2[1]:.3f} {end[0]:.3f} {end[1]:.3f}")

    # Shapes. `hole` winds the other way, to cut out of a shape drawn before it.

    def circle(self, cx, cy, r, hole=False):
        self.arc(cx, cy, r, 0, -2 * math.pi if hole else 2 * math.pi, start=True)
        self.close()

    def rounded_rect(self, x, y, w, h, r, hole=False):
        corners = [(x + w - r, y + r, -90), (x + w - r, y + h - r, 0), (x + r, y + h - r, 90), (x + r, y + r, 180)]
        if hole:
            corners = [(cx, cy, a + 90) for cx, cy, a in reversed(corners)]
        for i, (cx, cy, a) in enumerate(corners):
            a0 = math.radians(a)
            self.arc(cx, cy, r, a0, a0 + (-1 if hole else 1) * math.pi / 2, start=i == 0)
        self.close()

    def outline_rect(self, x, y, w, h, r, t=STROKE):
        self.rounded_rect(x, y, w, h, r)
        self.rounded_rect(x + t, y + t, w - 2 * t, h - 2 * t, max(r - t, 1), hole=True)

    def stroke_arc(self, cx, cy, r, a0, a1, t=STROKE):
        """A thick arc with round ends; angles in degrees, 0 = right, 90 = down, 270 = up."""
        a0, a1 = math.radians(a0), math.radians(a1)
        self.arc(cx, cy, r + t / 2, a0, a1, start=True)
        self.arc(cx + r * math.cos(a1), cy + r * math.sin(a1), t / 2, a1, a1 + math.pi)
        self.arc(cx, cy, r - t / 2, a1, a0)
        self.arc(cx + r * math.cos(a0), cy + r * math.sin(a0), t / 2, a0 + math.pi, a0 + 2 * math.pi)
        self.close()

    def headphones(self, cx, cy, r, t=STROKE, cup=(16, 32, 6.5), drop=None):
        """Over-ear headphones from the front: a band over the top and an earcup at each end."""
        w, h, corner = cup
        drop = h * 0.28 if drop is None else drop
        self.stroke_arc(cx, cy, r, 180, 360, t)
        for side in (-1, 1):
            self.rounded_rect(cx + side * r - w / 2, cy + drop - h / 2, w, h, corner)


def symbol_svg(path):
    d = "".join(path.d)
    weights = [("Ultralight", 600), ("Regular", 1400), ("Black", 2200)]
    guides, symbols = [], []
    for name, x in weights:
        guides.append(f'<line id="left-margin-{name}-S" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" '
                      f'x1="{x - 4}" x2="{x - 4}" y1="600" y2="720"/>')
        guides.append(f'<line id="right-margin-{name}-S" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" '
                      f'x1="{x + 124}" x2="{x + 124}" y1="600" y2="720"/>')
        symbols.append(f'<g id="{name}-S" transform="matrix(1 0 0 1 {x} 696)"><path d="{d}"/></g>')
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text id="template-version" style="stroke:none;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
 </g>
 <g id="Guides">
  <line id="Baseline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="696" y2="696"/>
  <line id="Capline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="625.541" y2="625.541"/>
  <line id="Baseline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1126" y2="1126"/>
  <line id="Capline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
  <line id="Baseline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1556" y2="1556"/>
  <line id="Capline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
  {" ".join(guides)}
 </g>
 <g id="Symbols">
  {" ".join(symbols)}
 </g>
</svg>
'''


# Thick lines and polygons, for the small marks.

def line(p, x0, y0, x1, y1, t=6.5, hole=False):
    a = math.atan2(y1 - y0, x1 - x0)
    if not hole:
        p.arc(x1, y1, t / 2, a - math.pi / 2, a + math.pi / 2, start=True)
        p.arc(x0, y0, t / 2, a + math.pi / 2, a + 3 * math.pi / 2)
    else:
        p.arc(x0, y0, t / 2, a + 3 * math.pi / 2, a + math.pi / 2, start=True)
        p.arc(x1, y1, t / 2, a + math.pi / 2, a - math.pi / 2)
    p.close()


def poly(p, points):
    p.move(*points[0])
    for point in points[1:]:
        p.line(*point)
    p.close()


# Marks: each draws itself around (x, y), about `s` across.

def plus(p, x, y, s, t=6.5):
    line(p, x - s / 2, y, x + s / 2, y, t)
    line(p, x, y - s / 2, x, y + s / 2, t)


def minus(p, x, y, s, t=6.5):
    line(p, x - s / 2, y, x + s / 2, y, t)


def letter_a(p, x, y, s, t=5.5):
    h = s * 1.05
    line(p, x - s * 0.42, y + h / 2, x, y - h / 2, t)
    line(p, x + s * 0.42, y + h / 2, x, y - h / 2, t)
    line(p, x - s * 0.22, y + h * 0.14, x + s * 0.22, y + h * 0.14, t * 0.9)


def swap(p, x, y, s, t=5.5):
    for dy, d in ((-s * 0.26, 1), (s * 0.26, -1)):
        line(p, x - s / 2, y + dy, x + s / 2, y + dy, t)
        tip = x + d * s / 2
        line(p, tip, y + dy, tip - d * s * 0.26, y + dy - s * 0.2, t)
        line(p, tip, y + dy, tip - d * s * 0.26, y + dy + s * 0.2, t)


def bubble(p, x, y, s):
    w, h = s * 1.15, s * 0.82
    p.rounded_rect(x - w / 2, y - h / 2 - s * 0.08, w, h, h * 0.36)
    poly(p, [(x - w * 0.22, y + h / 2 - s * 0.12), (x - w * 0.30, y + h / 2 + s * 0.22), (x + w * 0.04, y + h / 2 - s * 0.12)])


def person(p, x, y, s):
    p.circle(x, y - s * 0.24, s * 0.24)
    p.arc(x, y + s * 0.52, s * 0.46, math.pi, 2 * math.pi, start=True)
    p.close()


def mic(p, x, y, s, t=5):
    w = s * 0.36
    p.rounded_rect(x - w / 2, y - s * 0.56, w, s * 0.72, w / 2)
    p.stroke_arc(x, y - s * 0.08, s * 0.36, 0, 180, t)
    line(p, x, y + s * 0.30, x, y + s * 0.52, t)


def slashed_mic(p, x, y, s):
    mic(p, x, y, s)
    line(p, x - s * 0.43, y - s * 0.47, x + s * 0.43, y + s * 0.47, 5.5)


def link(p, x, y, s, t=5):
    # Two chain links, one through the other.
    d, half, wide = s * 0.21, s * 0.16, s * 0.40
    ux, uy = math.cos(-math.pi / 4), math.sin(-math.pi / 4)
    for side in (-1, 1):
        cx, cy = x + side * d * ux, y + side * d * uy
        line(p, cx - half * ux, cy - half * uy, cx + half * ux, cy + half * uy, wide)
        line(p, cx - half * ux, cy - half * uy, cx + half * ux, cy + half * uy, wide - 2 * t, hole=True)


def bars(p, x, y, s):
    w = s * 0.22
    for i, h in enumerate((0.38, 0.68, 1.0)):
        p.rounded_rect(x - s * 0.45 + i * s * 0.34, y + s / 2 - s * h, w, s * h, w * 0.4)


def clock(p, x, y, s, t=4.8):
    p.circle(x, y, s / 2)
    p.circle(x, y, s / 2 - t, hole=True)
    line(p, x, y, x, y - s * 0.25, t)
    line(p, x, y, x + s * 0.19, y + s * 0.09, t)


def sound(p, x, y, s, t=5):
    p.circle(x - s * 0.38, y, s * 0.13)
    for radius in (s * 0.36, s * 0.66):
        p.stroke_arc(x - s * 0.38, y, radius, -42, 42, t)


# Symbols. The headphones are in every one; what's around or inside them says which control it is.

def noise_cancelling():
    # Sealed off: the headphones inside a bubble.
    p = Path()
    p.circle(CX, CY, 51)
    p.circle(CX, CY, 51 - 6.5, hole=True)
    p.headphones(CX, CY + 3, 23, t=6.5, cup=(12.5, 25, 5))
    return p


def ambient(mark=None, size=22):
    # Open: sound waves arriving at each earcup from outside. A mark inside the band makes it a setting of that.
    p = Path()
    r, drop, cy = 27, 9, CY - 3
    p.headphones(CX, cy, r, cup=(15, 31, 6), drop=drop)
    for side, facing in ((-1, 180), (1, 0)):
        for radius in (19, 31):
            p.stroke_arc(CX + side * r, cy + drop, radius, facing - 36, facing + 36, t=6)
    if mark:
        mark(p, CX, cy + 8, size)
    return p


def framed(mark=None, size=30):
    # The headphones alone, or with a mark inside the band.
    p = Path()
    cy = CY - 2
    p.headphones(CX, cy, 37, cup=(18, 36, 7))
    if mark:
        mark(p, CX, cy + 7, size)
    return p


def badged(mark, badge, size=26, badge_size=28):
    # A mark inside the band and a second one at the lower right, where the earcup is cut short to make room.
    p = Path()
    cx, cy, r = CX - 5, CY - 8, 35
    p.stroke_arc(cx, cy, r, 180, 360)
    p.rounded_rect(cx - r - 8.5, cy - 7, 17, 34, 7)
    p.rounded_rect(cx + r - 8.5, cy - 7, 17, 21, 7)
    mark(p, cx, cy + 6, size)
    badge(p, cx + r + 2, cy + 34, badge_size)
    return p


def worn_by_phone():
    # The headphones are on the phone: it's the one playing.
    p = Path()
    p.outline_rect(CX - 17, CY - 26, 34, 62, 9, t=6.5)
    p.headphones(CX, CY - 12, 31, t=7, cup=(13.5, 28, 5.5))
    return p


def worn_by_laptop():
    p = Path()
    p.outline_rect(CX - 26, CY - 20, 52, 37, 6, t=6.5)
    p.rounded_rect(CX - 38, CY + 23, 76, 7, 3.5)
    p.headphones(CX, CY - 8, 39, t=7, cup=(12.5, 26, 5.5), drop=6)
    return p


def worn_by_tablet():
    p = Path()
    p.outline_rect(CX - 23, CY - 26, 46, 62, 8, t=6.5)
    p.headphones(CX, CY - 12, 36, t=7, cup=(13, 28, 5.5))
    return p


def worn_by_other():
    # Anything else (TV, speaker, watch): a plain box with a dot.
    p = Path()
    p.outline_rect(CX - 22, CY - 16, 44, 46, 10, t=6.5)
    p.circle(CX, CY + 7, 7)
    p.headphones(CX, CY - 6, 36, t=7, cup=(13, 27, 5.5), drop=6)
    return p


SYMBOLS = {
    "headphones.sealed": noise_cancelling,
    "headphones.waves": ambient,
    "headphones.plain": framed,
    "headphones.waves.plus": lambda: ambient(plus, 20),
    "headphones.waves.minus": lambda: ambient(minus, 20),
    "headphones.waves.auto": lambda: ambient(letter_a, 20),
    "headphones.waves.voice": lambda: ambient(person, 26),
    "headphones.on.phone": worn_by_phone,
    "headphones.on.laptop": worn_by_laptop,
    "headphones.on.tablet": worn_by_tablet,
    "headphones.on.device": worn_by_other,
    "headphones.link": lambda: framed(link, 40),
    "headphones.swap": lambda: framed(swap, 32),
    "headphones.mic": lambda: framed(mic, 40),
    "headphones.chat": lambda: framed(bubble, 32),
    "headphones.chat.level": lambda: badged(bubble, bars),
    "headphones.chat.timer": lambda: badged(bubble, clock),
    "headphones.mic.slash": lambda: framed(slashed_mic, 40),
    "headphones.mic.slash.sound": lambda: badged(slashed_mic, sound, size=34, badge_size=30),
}

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 2 and sys.argv[1] == "--json":
        # Just the outlines, for drawing previews.
        json.dump({name: "".join(draw().d) for name, draw in SYMBOLS.items()}, open(sys.argv[2], "w"))
        sys.exit()
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    for name, draw in SYMBOLS.items():
        folder = os.path.join(OUT, f"{name}.symbolset")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, f"{name}.svg"), "w") as f:
            f.write(symbol_svg(draw()))
        with open(os.path.join(folder, "Contents.json"), "w") as f:
            json.dump({"info": {"author": "xcode", "version": 1},
                       "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}]}, f, indent=2)
    print(f"wrote {len(SYMBOLS)} symbols to {os.path.normpath(OUT)}")
