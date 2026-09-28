#!/usr/bin/env python3
"""Rebuild the iPhone Duo's two frames in device_specs/apple-iphone-duo.json
from Apple's own simulator artwork.

The Duo breaks every assumption `extract_specs.py` makes about a phone:

* **Two displays.** `capabilities.plist` lists a `primary` display (the
  cover, `phone15` chrome) and a `primary-1` display (the inner one, `phone14`
  chrome), each with its own framebuffer mask. The spec's top-level `frame`
  is the inner display (the open posture); `postures.closed.frame` is the
  cover.
* **Asymmetric chrome.** The cover's bezel is wider on the hinge side (a
  separate spine strip, left 26 / right 22 in `chrome.json`), its corners are
  nearly square along the hinge and large squircles opposite, and its
  composite places the screen at x = 25 — so shapes are converted path by
  path, not as concentric rounded rectangles.
* **A composite drawn for the physical panel.** The inner chrome surrounds a
  626 x 890 pt panel — the real 1878 x 2670 px display at 3x — while iOS lays
  out 669 x 951 pt and downsamples; the artwork is scaled to the logical
  screen.

Only geometry and flat colors are derived (see SKILL.md, "Licensing note"):
strokes become fills of their outline offset outward by half the stroke
width (the next shape in paint order covers the inner half), clipped fills
become fills of their clip path. Buttons stay under the bezel, as in every
other frame.

Everything else in the spec — metrics, keyboard heights, reserved regions,
system UI — is measured on a booted simulator in each posture with
`posture_probe.swift` (SKILL.md, "iPhone Duo") and preserved as-is.

Usage (needs pymupdf):

    python extract_duo.py [--dry-run]
"""

import argparse
import json
import math
import os
import plistlib
import sys

import pymupdf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract_specs import (  # noqa: E402
    SPECS, developer_dir, find_device_type, fmt, fmt_json, hex_color,
    load_chrome_json, mask_subpaths)

SPEC_ID = "apple-iphone-duo"
SIM_NAME = "iPhone Duo"

# The cover camera, from UIKit's own occlusion region for it
# (`UIView.reservedRegions(kind: .occlusion)` on the booted cover display):
# a 37 pt disc 29.33 pt from the top and right edges. The masks carry no
# cutout — iOS draws the camera housing itself, as it does the Dynamic
# Island — so it is appended as a counter-clockwise subpath.
COVER_CAMERA = (418.17, 47.83, 18.5)

CHROME_ROOTS = ["/Library/Developer/DeviceKit/Chrome"]

# How far each side of the body pinches in at the hinge when the device is
# partially open, in points: Device Hub draws the half-open Duo with its long
# edges bent into a shallow V meeting at the fold (~14 pt at the default
# angle). Body and screen outline bend together, so the bezel keeps its
# thickness; the app is laid out flat, as on the device, and clipped where
# the panel turns away.
HALF_OPEN_PINCH = 10


def chrome_dir(dev, chrome_id):
    short = chrome_id.rsplit(".", 1)[-1]
    roots = CHROME_ROOTS + [os.path.join(
        dev, "Platforms/iPhoneOS.platform/Library/Developer/DeviceKit/Chrome")]
    for root in roots:
        path = os.path.join(root, f"{short}.devicechrome", "Contents",
                            "Resources")
        if os.path.isdir(path):
            return path
    sys.exit(f"error: chrome bundle not found: {short} (looked in {roots})")


# --- path geometry -----------------------------------------------------------

def segments_of(items):
    """PyMuPDF path items -> [(kind, [points])], kind 'L' or 'C'."""
    out = []
    for item in items:
        op = item[0]
        if op == "l":
            out.append(("L", [(item[1].x, item[1].y), (item[2].x, item[2].y)]))
        elif op == "c":
            out.append(("C", [(p.x, p.y) for p in item[1:5]]))
        elif op == "re":
            r = item[1]
            corners = [(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1)]
            subpath = [("L", [corners[i], corners[(i + 1) % 4]])
                       for i in range(4)]
            out.append(("SUB", subpath))
        else:
            sys.exit(f"error: unsupported path item {op}")
    return out


def subpaths_of(items):
    """Split into closed subpaths (a `re` is its own subpath)."""
    subs, current = [], []
    for seg in segments_of(items):
        if seg[0] == "SUB":
            subs.append(seg[1])
            continue
        if current and dist(current[-1][1][-1], seg[1][0]) > 0.01:
            subs.append(current)
            current = []
        current.append(seg)
    if current:
        subs.append(current)
    return subs


def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def signed_area(sub):
    pts = [seg[1][0] for seg in sub]
    return sum(pts[i][0] * pts[(i + 1) % len(pts)][1] -
               pts[(i + 1) % len(pts)][0] * pts[i][1]
               for i in range(len(pts))) / 2


def unit_normal(a, b, outward_sign):
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = math.hypot(dx, dy)
    if length < 1e-9:
        return None
    # y-down space: for a positively wound (clockwise on screen) path the
    # outward normal of direction (dx, dy) is (dy, -dx).
    return (outward_sign * dy / length, -outward_sign * dx / length)


def intersect(p, d, q, e):
    """Intersection of lines p + t d and q + s e, or None if parallel."""
    den = d[0] * e[1] - d[1] * e[0]
    if abs(den) < 1e-9:
        return None
    t = ((q[0] - p[0]) * e[1] - (q[1] - p[1]) * e[0]) / den
    return (p[0] + t * d[0], p[1] + t * d[1])


def offset_subpath(sub, amount):
    """Offset a closed path of lines and cubics outward by `amount`
    (Tiller-Hanson on each control polygon, mitered joins). Exact for lines
    and circular-ish corners at the few-point offsets bezels need."""
    sign = 1 if signed_area(sub) > 0 else -1
    shifted = []
    for kind, pts in sub:
        # Offset each non-degenerate edge of the control polygon.
        edges = []
        for a, b in zip(pts, pts[1:]):
            n = unit_normal(a, b, sign)
            edges.append(None if n is None else (
                (a[0] + amount * n[0], a[1] + amount * n[1]),
                (b[0] - a[0], b[1] - a[1])))
        live = [e for e in edges if e is not None]
        if not live:
            continue
        if kind == "L":
            p, d = live[0]
            shifted.append(("L", [p, (p[0] + d[0], p[1] + d[1])]))
            continue
        # Cubic: endpoints move along the first / last live edge normals,
        # inner control points sit where adjacent offset edges intersect.
        first, last = live[0], live[-1]
        p0 = first[0]
        p3 = (last[0][0] + last[1][0], last[0][1] + last[1][1])
        if len(live) == 3:
            p1 = intersect(live[0][0], live[0][1], live[1][0], live[1][1])
            p2 = intersect(live[1][0], live[1][1], live[2][0], live[2][1])
        else:
            p1 = p2 = None
        if p1 is None:
            n = unit_normal(pts[0], pts[1], sign) or unit_normal(
                pts[0], pts[3], sign)
            p1 = (pts[1][0] + amount * n[0], pts[1][1] + amount * n[1])
        if p2 is None:
            n = unit_normal(pts[2], pts[3], sign) or unit_normal(
                pts[0], pts[3], sign)
            p2 = (pts[2][0] + amount * n[0], pts[2][1] + amount * n[1])
        shifted.append(("C", [p0, p1, p2, p3]))
    # Joins: where two offset segments no longer meet (a sharp corner), move
    # both to the miter point.
    for i in range(len(shifted)):
        a = shifted[i]
        b = shifted[(i + 1) % len(shifted)]
        end, start = a[1][-1], b[1][0]
        if dist(end, start) < 0.01:
            continue
        da = (a[1][-1][0] - a[1][-2][0], a[1][-1][1] - a[1][-2][1])
        db = (b[1][1][0] - b[1][0][0], b[1][1][1] - b[1][0][1])
        miter = intersect(end, da, start, db) or end
        a[1][-1] = miter
        b[1][0] = miter
    return shifted


def path_data(subs, sx, sy, dx=0.0, dy=0.0):
    def pt(p):
        return f"{fmt((p[0] - dx) * sx)},{fmt((p[1] - dy) * sy)}"
    parts = []
    for sub in subs:
        parts.append("M " + pt(sub[0][1][0]))
        for kind, pts in sub:
            parts.append(kind + " " + " ".join(pt(p) for p in pts[1:]))
        parts.append("Z")
    return " ".join(parts)


# --- chrome -> body SVG ------------------------------------------------------

def composite_body(resources, chrome, sx, sy):
    """Body SVG lines, the screen rect in composite space, and the page size.

    Paint order is the composite's own. A stroke of width w becomes a fill
    of its path offset outward by w / 2; a clipped fill becomes a fill of
    the clip path (its own geometry is only a rectangle larger than the
    clip).
    """
    page = pymupdf.open(os.path.join(
        resources, chrome["images"]["composite"] + ".pdf"))[0]
    shapes, clip, screen = [], None, None
    for item in page.get_drawings(extended=True):
        kind = item["type"]
        if kind == "clip":
            clip = item
            continue
        if kind == "s" and item.get("width"):
            subs = [offset_subpath(sub, item["width"] / 2)
                    for sub in subpaths_of(item["items"])]
            opacity = item.get("stroke_opacity") or 1.0
            shapes.append((subs, item["color"], opacity, None))
            screen = item["rect"]  # the last stroke rings the screen
            continue
        if kind != "f":
            continue
        source = clip if clip is not None and item.get("level", 0) > 0 \
            else item
        subs = subpaths_of(source["items"])
        rule = "evenodd" if source.get("even_odd") and len(subs) > 1 \
            else None
        shapes.append((subs, item["fill"], item.get("fill_opacity") or 1.0,
                       rule))
        clip = None
    if screen is None:
        sys.exit(f"error: no screen ring in {resources}")
    w, h = page.rect.width * sx, page.rect.height * sy
    lines = [f'<svg viewBox="0 0 {fmt(w)} {fmt(h)}">']
    for subs, color, opacity, rule in shapes:
        attrs = f'd="{path_data(subs, sx, sy)}" fill="{hex_color(color)}"'
        if opacity < 1.0:
            attrs += f' fill-opacity="{fmt(opacity)}"'
        if rule:
            attrs += f' fill-rule="{rule}"'
        lines.append(f"  <path {attrs}/>")
    lines.append("</svg>")
    return lines, screen, (w, h)


def bend_paths(d, center_x, fold_y, half, pinch):
    """Path data `d` bent the way a half-open device looks: every point
    shifted toward the vertical line `center_x` by `pinch` on the fold line,
    tapering to nothing `half` away from it — each long edge becomes a V
    meeting at the hinge.

    The shift is the same at every depth, so applied to the body and to the
    screen outline alike the bezel keeps its thickness into the V and the
    screen bends with it (the app, laid out flat as on the device, is clipped
    by the bent outline where the panel turns away).

    Straight segments that cross the fold are split there first — otherwise
    a long edge keeps its far-away endpoints and stays straight.
    """
    import re

    def bend(x, y):
        t = max(0.0, 1 - abs(y - fold_y) / half)
        return (x + pinch * t if x < center_x else x - pinch * t, y)

    tokens = re.findall(r"[MLCZA]|-?\d+(?:\.\d+)?(?:,-?\d+(?:\.\d+)?)?", d)
    if "A" in tokens:
        return d  # arcs (the cover's camera) are never on the bent edges
    out, pen, op = [], None, None
    for token in tokens:
        if token in "MLCZ":
            op = token
            if token == "Z":
                out.append("Z")
            continue
        x, y = (float(v) for v in token.split(","))
        if op == "L" and pen is not None and \
                (pen[1] - fold_y) * (y - fold_y) < 0:
            t = (fold_y - pen[1]) / (y - pen[1])
            bx, by = bend(pen[0] + t * (x - pen[0]), fold_y)
            out.append(f"L {fmt(bx)},{fmt(by)}")
        bx, by = bend(x, y)
        if op == "C":
            if not out or not out[-1].startswith("C") or \
                    out[-1].count(",") == 3:
                out.append(f"C {fmt(bx)},{fmt(by)}")
            else:
                out[-1] += f" {fmt(bx)},{fmt(by)}"
        else:
            out.append(f"{op} {fmt(bx)},{fmt(by)}")
            if op == "M":
                op = "L"
        pen = (x, y)
    return " ".join(out)


def bend_frame(frame, screen_size, pinch):
    """The open frame, bent at the fold (mid-height of the portrait
    screen) into its half-open look — body and screen outline together."""
    import re
    ox, oy = frame["screenOffset"]["x"], frame["screenOffset"]["y"]
    w, h = frame["size"]["width"], frame["size"]["height"]
    fold_y = oy + screen_size[1] / 2
    half = max(fold_y, h - fold_y)

    def bend_line(line):
        match = re.search(r'd="([^"]+)"', line)
        if match is None:
            return line
        return line.replace(match.group(1),
                            bend_paths(match.group(1), w / 2, fold_y, half,
                                       pinch))

    bent = dict(frame)
    bent["body"] = [bend_line(line) for line in frame["body"]]
    # The screen outline is in screen coordinates: same bend, same fold.
    bent["screenPath"] = bend_paths(frame["screenPath"], screen_size[0] / 2,
                                    screen_size[1] / 2, half, pinch)
    return bent


def screen_outline(mask_pdf, logical):
    subpaths, page_w, page_h = mask_subpaths(mask_pdf)
    unit_x, unit_y = page_w / logical[0], page_h / logical[1]
    if abs(unit_x - unit_y) > 1e-3:
        sys.exit(f"error: anisotropic mask page in {mask_pdf}")
    parts = []
    for sub in subpaths:
        for op, nums in sub:
            if op == "Z":
                parts.append("Z")
                continue
            pairs = [f"{fmt(nums[i] / unit_x)},"
                     f"{fmt((page_h - nums[i + 1]) / unit_y)}"
                     for i in range(0, len(nums), 2)]
            parts.append(op + " " + " ".join(pairs))
        if sub[-1][0] != "Z":
            parts.append("Z")
    return " ".join(parts)


def circle_ccw(cx, cy, r):
    """A circle wound counter-clockwise (on screen), to punch a hole."""
    return (f"M {fmt(cx)},{fmt(cy - r)} "
            f"A {fmt(r)},{fmt(r)} 0 1 0 {fmt(cx)},{fmt(cy + r)} "
            f"A {fmt(r)},{fmt(r)} 0 1 0 {fmt(cx)},{fmt(cy - r)} Z")


def build_frame(dev, device_type, display, logical, extra_path=None):
    resources = chrome_dir(dev, display["chromeIdentifier"])
    chrome = load_chrome_json(resources)
    page = pymupdf.open(os.path.join(
        resources, chrome["images"]["composite"] + ".pdf"))[0]
    # The composite's screen ring locates the panel it was drawn around;
    # scale that panel onto the logical screen.
    ring = next(i for i in reversed(page.get_drawings())
                if i["type"] == "s" and i.get("width"))["rect"]
    sx, sy = logical[0] / ring.width, logical[1] / ring.height
    body, screen, size = composite_body(resources, chrome, sx, sy)
    mask = os.path.join(device_type, "Contents/Resources",
                        display["framebufferMaskIdentifier"] + ".pdf")
    path = screen_outline(mask, logical)
    if extra_path:
        path += " " + extra_path
    short = display["chromeIdentifier"].rsplit(".", 1)[-1]
    print(f"  {display['deviceName']}: {short} panel "
          f"{fmt(ring.width)}x{fmt(ring.height)} -> "
          f"{fmt(logical[0])}x{fmt(logical[1])} (x{fmt(sx)}), body "
          f"{fmt(size[0])}x{fmt(size[1])}, screen at "
          f"{fmt(screen.x0 * sx)},{fmt(screen.y0 * sy)}")
    return {
        "size": {"width": fmt_json(round(size[0], 2)),
                 "height": fmt_json(round(size[1], 2))},
        "screenOffset": {"x": fmt_json(round(screen.x0 * sx, 2)),
                         "y": fmt_json(round(screen.y0 * sy, 2))},
        "screenPath": path,
        "body": body,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    dev = developer_dir()
    device_type = find_device_type(dev, SIM_NAME)
    if device_type is None:
        sys.exit(f"error: no {SIM_NAME} device type — install the iOS 27.1 "
                 "simulator platform (xcodebuild -downloadPlatform iOS)")
    capabilities = plistlib.load(open(os.path.join(
        device_type, "Contents/Resources/capabilities.plist"), "rb"))
    displays = {d["deviceName"]: d
                for d in capabilities["capabilities"]["displays"]}
    cover, inner = displays["primary"], displays["primary-1"]

    spec_path = os.path.join(SPECS, f"{SPEC_ID}.json")
    original = open(spec_path).read()
    spec = json.loads(original)

    def logical(display):
        return (display["width"] / display["scale"],
                display["height"] / display["scale"])

    open_size = spec["portraitSize"]
    closed_size = spec["postures"]["closed"]["portraitSize"]
    for name, display, size in (("open", inner, open_size),
                                ("closed", cover, closed_size)):
        if logical(display) != (size["width"], size["height"]):
            sys.exit(f"error: the {name} spec screen is "
                     f"{size['width']}x{size['height']} but the simulator's "
                     f"{display['deviceName']} display is "
                     f"{logical(display)[0]:g}x{logical(display)[1]:g}")

    print(f"{SPEC_ID} (from {SIM_NAME})")
    spec["frame"] = build_frame(dev, device_type, inner, logical(inner))
    # Half-open: the same screen, body and outline bent at the fold.
    bent = bend_frame(spec["frame"], logical(inner), HALF_OPEN_PINCH)
    spec["postures"]["halfOpened"]["frame"] = bent
    spec["postures"]["closed"]["frame"] = build_frame(
        dev, device_type, cover, logical(cover),
        extra_path=circle_ccw(*COVER_CAMERA))
    if not args.dry_run:
        text = json.dumps(spec, indent=2)
        if original.endswith("\n"):
            text += "\n"
        open(spec_path, "w").write(text)


if __name__ == "__main__":
    main()
