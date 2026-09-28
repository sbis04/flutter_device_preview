#!/usr/bin/env python3
"""Rebuild the iPhone Duo's status bar artwork in
device_specs/apple-iphone-duo.json from Apple's iOS 27 UI kit.

Input: the kit's "Status bar - iPhone Duo" component, both variants exported
from Figma as SVG (Apple Design Resources ▸ iOS and iPadOS 27 ▸ page "Status
Bars and Menu Bars" ▸ select `Type=Horizontal` / `Type=Vertical` ▸ Export
▸ SVG):

    python duo_status_bar.py Type=Horizontal.svg Type=Vertical.svg

Each variant is the clock ("9:41", outlined), the wifi glyph, the battery
level ring around it and four cellular dots under it. Path data is kept
verbatim; only what the embedded renderer cannot draw is converted:

* the battery ring is a 3 pt stroked arc with round caps — strokes are not
  in the SVG subset, so it becomes a filled annular arc with round ends;
* `fill="black"` becomes `currentColor`, so the app's status bar style tints
  it;
* the cellular dots are drawn at 25% (`fill-opacity`): what the simulator
  shows, which has no cellular service. (A device with full signal draws
  them solid.)

Placement is not the kit's: it was fitted, pixel by pixel, against the
iOS 27.1 simulator with the status bar pinned to 9:41 (`xcrun simctl
status_bar booted override --time 9:41 --batteryState discharging
--batteryLevel 100`), template-matching the kit glyph at 3x in each pose:

* stacked (`Vertical`), in the side column (`systemUi.sideBar`) — its
  48 pt frame's left edge 30 pt left of the column center, i.e. centered
  under the camera; top 71.67 pt on the cover (portrait), 19 pt on the open
  display (landscape);
* in a row (`Horizontal`), in the top bar of the open display in portrait
  (`systemUi.statusBar.trailing`) — frame at x 541.33, y 24.33 in the
  669 pt screen, with iOS setting the clock 9 pt further left than the kit's
  auto layout does.
"""

import json
import math
import os
import re
import sys

SKILL_DIR = os.path.dirname(os.path.abspath(__file__))
SPEC = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    SKILL_DIR))), "device_specs", "apple-iphone-duo.json")

# Fitted on the iOS 27.1 simulator (see the docstring).
COLUMN_WIDTH = 60        # artwork width centered in the 84 pt side column
COVER_COLUMN_TOP = 71.67
OPEN_COLUMN_TOP = 19
ROW_CLOCK_SHIFT = 9      # iOS sets the row's clock this much further left
ROW_RIGHT_INSET = 23.67  # the row's right edge, from the screen's
ROW_BOTTOM_INSET = 9.67  # the row's bottom, from the 82 pt top bar's
DOT_OPACITY = 0.25


def fmt(v):
    r = round(v, 3)
    return str(int(r)) if r == int(r) else f"{r:g}"


def elements(svg):
    return re.findall(r"<(path|circle)\b([^>]*?)/?>", svg)


def attr(attrs, name):
    m = re.search(rf'\b{name}="([^"]*)"', attrs)
    return m.group(1) if m else None


def ring_fill(d, width):
    """A stroked circular arc (`M start C … end`, round caps) as a filled
    annular arc: the outer arc, a round cap, the inner arc back, a cap."""
    nums = [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?", d)]
    pts = list(zip(nums[0::2], nums[1::2]))
    start, end = pts[0], pts[-1]
    # A circle: the ends are symmetric about its vertical axis, the
    # leftmost x is one radius from it and the top one radius above center.
    # (Control points share those extremes, so only the extremes are read.)
    cx = (start[0] + end[0]) / 2
    radius = cx - min(x for x, _ in pts)
    cy = min(y for _, y in pts) + radius
    a0 = math.atan2(start[1] - cy, start[0] - cx)
    a1 = math.atan2(end[1] - cy, end[0] - cx)
    h = width / 2
    ro, ri = radius + h, radius - h

    def p(r, a):
        return f"{fmt(cx + r * math.cos(a))},{fmt(cy + r * math.sin(a))}"

    # The arc runs clockwise on screen from start over the top to end — the
    # long way round (the gap is at the bottom, where the dots are).
    return (f"M {p(ro, a0)} A {fmt(ro)},{fmt(ro)} 0 1 1 {p(ro, a1)} "
            f"A {fmt(h)},{fmt(h)} 0 0 1 {p(ri, a1)} "
            f"A {fmt(ri)},{fmt(ri)} 0 1 0 {p(ri, a0)} "
            f"A {fmt(h)},{fmt(h)} 0 0 1 {p(ro, a0)} Z")


def convert(svg, clock_dx=0.0):
    """The variant as the spec's SVG subset, its clock shifted by
    `clock_dx` (the clock is the first path, as the kit exports it)."""
    out, first = [], True
    for tag, attrs in elements(svg):
        if tag == "circle":
            out.append(f'  <circle cx="{attr(attrs, "cx")}" '
                       f'cy="{attr(attrs, "cy")}" r="{attr(attrs, "r")}" '
                       f'fill="currentColor" fill-opacity="{DOT_OPACITY}"/>')
            continue
        d = attr(attrs, "d")
        if attr(attrs, "stroke"):
            out.append(f'  <path d="{ring_fill(d, float(attr(attrs, "stroke-width")))}" '
                       f'fill="currentColor"/>')
            continue
        rule = attr(attrs, "fill-rule")
        extra = f' fill-rule="{rule}"' if rule else ""
        line = f'  <path d="{d}" fill="currentColor"{extra}/>'
        if first and clock_dx:
            line = (f'  <g transform="translate({fmt(clock_dx)}, 0)">\n  '
                    f'{line}\n  </g>')
        first = False
        out.append(line)
    return out


def size(svg):
    w, h = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', svg).groups()
    return float(w), float(h)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    horizontal = open(sys.argv[1]).read()
    vertical = open(sys.argv[2]).read()

    vw, vh = size(vertical)
    column = ([f'<svg viewBox="0 0 {fmt(COLUMN_WIDTH)} {fmt(vh)}">']
              + convert(vertical) + ["</svg>"])
    hw, hh = size(horizontal)
    # Room on the left for the clock iOS moves out of the kit's frame.
    row = ([f'<svg viewBox="0 0 {fmt(hw + ROW_CLOCK_SHIFT)} {fmt(hh)}">',
            f'  <g transform="translate({fmt(ROW_CLOCK_SHIFT)}, 0)">']
           + ["  " + line for line in
              convert(horizontal, clock_dx=-ROW_CLOCK_SHIFT)]
           + ["  </g>", "</svg>"])

    spec = json.load(open(SPEC))
    spec["systemUi"]["statusBar"] = {
        "inset": ROW_RIGHT_INSET,
        "bottomInset": ROW_BOTTOM_INSET,
        "trailing": row,
    }
    spec["systemUi"]["sideBar"] = {"inset": OPEN_COLUMN_TOP, "leading": column}
    spec["postures"]["closed"]["systemUi"]["sideBar"] = {
        "inset": COVER_COLUMN_TOP,
        "leading": column,
    }
    open(SPEC, "w").write(json.dumps(spec, indent=2) + "\n")
    print(f"wrote {SPEC}: row {fmt(hw + ROW_CLOCK_SHIFT)}x{fmt(hh)}, "
          f"column {fmt(COLUMN_WIDTH)}x{fmt(vh)}")


if __name__ == "__main__":
    main()
