"""Android foldables -> the `postures` of their device specs.

Rebuilds the open, half-open and closed postures of the Android foldables in
device_specs/ from two sources:

* the official emulator skins — Google's for the Pixel fold (bundled with
  Android Studio: a `default` and a `closed` skin), Samsung's for the Galaxy Z
  line (downloaded from developer.samsung.com, one `Main_Screen` and one
  `Cover_Screen` skin each) — for the frame artwork, the screen outline and
  the camera cutout;
* live emulator measurements, recorded in `measurements.json` next to this
  script (see SKILL.md for how each was taken): the safe areas Android
  applies and where its status bar and gesture pill sit, per posture.

usage: extract_foldable_specs.py [--dry-run] [--samsung-dir DIR] [ids...]
"""
import argparse
import json
import os
import re
import sys

import numpy as np
from PIL import Image, ImageFilter

SKILL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(SKILL_DIR)))
SPECS = os.path.join(REPO, "device_specs")
sys.path.insert(0, os.path.join(os.path.dirname(SKILL_DIR),
                                "extract-pixel-specs"))
import extract_pixel_specs as pixel  # noqa: E402

fmt, fmt_json = pixel.fmt, pixel.fmt_json

# Android's shared software keyboard heights (see the Pixel skill).
KEYBOARD = (336, 252)


def rounded(v):
    return fmt_json(round(v, 2))


def insets(values):
    left, top, right, bottom = values
    return {"left": rounded(left), "top": rounded(top),
            "right": rounded(right), "bottom": rounded(bottom)}


def rect(values):
    left, top, right, bottom = values
    return {"left": rounded(left), "top": rounded(top),
            "right": rounded(right), "bottom": rounded(bottom)}


def pill_svg(width, height):
    r = height / 2
    return [
        f'<svg viewBox="0 0 {fmt(width)} {fmt(height)}">',
        f'  <path d="M {fmt(r)},0 H {fmt(width - r)} A {fmt(r)},{fmt(r)} 0 0 1 '
        f'{fmt(width - r)},{fmt(height)} H {fmt(r)} A {fmt(r)},{fmt(r)} 0 0 1 '
        f'{fmt(r)},0 Z" fill="currentColor"/>',
        "</svg>",
    ]


def system_ui(base, measured):
    """The spec's status bar artwork, placed where Android places it."""
    status = dict(base["statusBar"])
    for key in ("inset", "trailingInset", "cutoutGap", "trailingCutoutGap"):
        status.pop(key, None)
        if key in measured["statusBar"]:
            status[key] = rounded(measured["statusBar"][key])
    pill = measured["pill"]
    return {
        "statusBar": {k: status[k] for k in
                      ("inset", "trailingInset", "cutoutGap",
                       "trailingCutoutGap", "leading", "center", "trailing")
                      if k in status},
        "navigationBar": {"center": pill_svg(pill["width"], pill["height"]),
                          "bottomInset": rounded(pill["bottomInset"])},
    }


# --- Samsung skins -----------------------------------------------------------

def samsung_layout(skin_dir):
    text = open(os.path.join(skin_dir, "layout")).read()
    image = re.search(r"image\s+(\S+)", text).group(1)
    display = re.search(r"display\s*\{[^}]*width\s+(\d+)[^}]*height\s+(\d+)",
                        text, re.S)
    device = re.search(r"part2\s*\{[^}]*x\s+(\d+)[^}]*y\s+(\d+)", text, re.S)
    return (os.path.join(skin_dir, image),
            (int(display.group(1)), int(display.group(2))),
            (int(device.group(1)), int(device.group(2))))


def samsung_body(skin_dir):
    image, _, _ = samsung_layout(skin_dir)
    return samsung_body_of(skin_dir, image)


def samsung_body_of(skin_dir, image):
    """The device silhouette in a Samsung skin: its art sits on a full-bleed
    blue-grey backdrop (with the model name printed beside it), not on
    transparency, so the body is what is neutral grey or near black —
    opened to drop the thin side buttons and the label strokes — and
    connected to the screen."""
    _, (sw, sh), (sx, sy) = samsung_layout(skin_dir)
    rgb = np.asarray(Image.open(image).convert("RGB")).astype(int)
    r, b = rgb[..., 0], rgb[..., 2]
    device = ((b - r) < 12) | (rgb.max(2) < 24)
    mask = Image.fromarray((device * 255).astype(np.uint8))
    mask = mask.filter(ImageFilter.MinFilter(9)).filter(ImageFilter.MaxFilter(9))
    device = np.asarray(mask) > 128
    h, w = device.shape
    seen = np.zeros_like(device)
    stack = [(sy + sh // 2, sx + sw // 2)]
    seen[stack[0]] = True
    while stack:
        y, x = stack.pop()
        for yy, xx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
            if 0 <= yy < h and 0 <= xx < w and device[yy, xx] and \
                    not seen[yy, xx]:
                seen[yy, xx] = True
                stack.append((yy, xx))
    return rgb, seen, (sx, sy, sw, sh)


def corner_radius(mask, corner):
    """The radius of a silhouette's corner: how far along the box's edge row
    the first solid pixel sits, as the Pixel skill measures bodies."""
    m = mask
    if corner in ("tr", "br"):
        m = m[:, ::-1]
    if corner in ("bl", "br"):
        m = m[::-1]
    ys, xs = np.where(m)
    top, left = ys.min(), xs.min()
    row = np.where(m[top])[0]
    col = np.where(m[:, left])[0]
    return float(max(row.min() - left, col.min() - top))


def rounded_path(w, h, radii):
    tl, tr, br, bl = radii
    parts = [f"M {fmt(tl)},0", f"H {fmt(w - tr)}"]
    if tr:
        parts.append(f"A {fmt(tr)},{fmt(tr)} 0 0 1 {fmt(w)},{fmt(tr)}")
    parts.append(f"V {fmt(h - br)}")
    if br:
        parts.append(f"A {fmt(br)},{fmt(br)} 0 0 1 {fmt(w - br)},{fmt(h)}")
    parts.append(f"H {fmt(bl)}")
    if bl:
        parts.append(f"A {fmt(bl)},{fmt(bl)} 0 0 1 0,{fmt(h - bl)}")
    parts.append(f"V {fmt(tl)}")
    if tl:
        parts.append(f"A {fmt(tl)},{fmt(tl)} 0 0 1 {fmt(tl)},0")
    return " ".join(parts) + " Z"


def mask_geometry(skin_dir, screen_px, turn=False):
    """Screen corner radii and the cutouts (camera holes, and on the Flip's
    cover the camera rings) from a Samsung `fore_port.png`: opaque pixels
    cover the screen. Some masks carry a hairline opaque border, ignored.
    [turn] reads it turned a quarter clockwise."""
    alpha = np.asarray(Image.open(os.path.join(skin_dir, "fore_port.png"))
                       .convert("RGBA"))[..., 3] >= pixel.OPAQUE
    if turn:
        alpha = np.rot90(alpha, k=-1)
    h, w = alpha.shape
    border = 0
    while alpha[border].mean() > 0.95 and alpha[:, border].mean() > 0.95:
        border += 1
    inner = alpha[border:h - border, border:w - border]
    radii = []
    for flip in ((False, False), (True, False), (True, True), (False, True)):
        m = inner[:, ::-1] if flip[0] else inner
        m = m[::-1] if flip[1] else m
        grid = [list(row) for row in m[:max(200, m.shape[0] // 6)]]
        fitted = pixel.fit_corner_radius(grid, m.shape[1])
        if not fitted:
            # Too small an arc to fit: the overlay's run along the edge row.
            run = int(np.argmin(m[0])) if m[0, 0] else 0
            fitted = run if run < m.shape[1] // 2 else 0
        radii.append(float(fitted))
    # Islands that touch no edge are cutouts; rings nested in rings merge.
    labels = np.zeros(inner.shape, int)
    islands = []
    ih, iw = inner.shape
    for y0, x0 in zip(*np.where(inner)):
        if labels[y0, x0]:
            continue
        stack, pts, edge = [(y0, x0)], [], False
        labels[y0, x0] = len(islands) + 1
        while stack:
            y, x = stack.pop()
            pts.append((y, x))
            if y in (0, ih - 1) or x in (0, iw - 1):
                edge = True
            for yy, xx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                if 0 <= yy < ih and 0 <= xx < iw and inner[yy, xx] and \
                        not labels[yy, xx]:
                    labels[yy, xx] = len(islands) + 1
                    stack.append((yy, xx))
        ys = [p[0] for p in pts]
        xs = [p[1] for p in pts]
        box = (min(xs) + border, min(ys) + border,
               max(xs) + 1 + border, max(ys) + 1 + border)
        islands.append((edge, box, len(pts)))
    holes = [box for edge, box, n in islands if not edge and n > 40]
    holes = [a for a in holes if not any(
        b != a and b[0] <= a[0] and b[1] <= a[1] and b[2] >= a[2] and
        b[3] >= a[3] for b in holes)]
    return {"radii": radii, "holes": holes, "size": (w, h)}


def _body_box(body, screen):
    """The body's box without the side buttons: the most common row and
    column extents across the screen."""
    sx, sy, sw, sh = screen
    rows = [np.where(body[y])[0] for y in range(sy, sy + sh, 7)]
    cols = [np.where(body[:, x])[0] for x in range(sx, sx + sw, 7)]
    return (int(np.median([r.min() for r in rows])),
            int(np.median([c.min() for c in cols])),
            int(np.median([r.max() for r in rows])) + 1,
            int(np.median([c.max() for c in cols])) + 1)


def diagonal_radius(mask, corner):
    """A silhouette corner's radius from how far along the 45° diagonal its
    first solid pixel sits: t = r (1 − 1/√2) for a circular corner."""
    m = mask
    if corner in ("tr", "br"):
        m = m[:, ::-1]
    if corner in ("bl", "br"):
        m = m[::-1]
    t = 0
    while t < min(m.shape) // 2 and not m[t, t]:
        t += 1
    return t / (1 - 2 ** -0.5)


def samsung_buttons(skin_dir, turn=False):
    """The skin's keys — the volume rocker (its two halves as one) and the
    power key — as (side, start, end) in canvas px along the edge they sit
    on, read from the skin layout's `buttons`. [turn] turns the canvas a
    quarter clockwise, (x, y) -> (H - y, x), as the Fold8's wide main skin
    is turned into the spec's portrait."""
    text = open(os.path.join(skin_dir, "layout")).read()
    _, (sw, sh), (sx, sy) = samsung_layout(skin_dir)
    canvas_h = Image.open(samsung_layout(skin_dir)[0]).size[1]
    keys = {}
    for name in ("volume-up", "volume-down", "power"):
        m = re.search(name + r"\s*\{[^}]*image\s+(\S+)[^}]*x\s+(\d+)"
                      r"[^}]*y\s+(\d+)", text, re.S)
        if m:
            w, h = Image.open(os.path.join(skin_dir, m.group(1))).size
            keys[name] = (int(m.group(2)), int(m.group(3)), w, h)
    runs = []
    if "volume-up" in keys and "volume-down" in keys:
        ux, uy, uw, uh = keys["volume-up"]
        dx, dy, dw, dh = keys["volume-down"]
        runs.append((min(ux, dx), min(uy, dy), max(uw, dw),
                     max(uy + uh, dy + dh) - min(uy, dy)))
    if "power" in keys:
        runs.append(keys["power"])
    out = []
    for x, y, w, h in runs:
        # (side, start, end, outer): outer is the key's far edge, across.
        if w < h:  # a key on a side edge
            side = "right" if x > sx + sw / 2 else "left"
            start, end = y, y + h
            outer = x + w if side == "right" else x
        else:
            side = "bottom" if y > sy + sh / 2 else "top"
            start, end = x, x + w
            outer = y + h if side == "bottom" else y
        if turn:
            side = {"right": "bottom", "left": "top", "top": "right",
                    "bottom": "left"}[side]
            if side in ("top", "bottom"):  # was a side edge: y -> x' = H - y
                start, end = canvas_h - end, canvas_h - start
            else:  # was top/bottom: across y -> x' = H - y
                outer = canvas_h - outer
        out.append((side, start, end, outer))
    return out


def template_colors(open_body):
    """The open frame's palette, in its drawing order: buttons, rim, body,
    bezel (the sheen is white)."""
    text = "\n".join(open_body)
    button = re.search(r'<g fill="(#[0-9a-f]{6})">', text).group(1)
    fills = re.findall(r'<path d="[^"]*"(?: transform="[^"]*")?'
                       r' fill="(#[0-9a-f]{6})"/>', text)
    return button, fills[0], fills[1], fills[-1]


def samsung_cover_frame(skin_dir, dpr, open_frame, turn=False):
    """A Samsung skin drawn in the catalog's Samsung frame style — side keys,
    rim, body, a diagonal sheen, bezel — at the skin's own body size,
    corners, screen position and key positions; the screen outline and its
    camera cutouts come from the skin's mask. [open_frame] gives the
    palette (the frame's fills, recoloured per finish at paint time).
    [turn] turns the skin a quarter clockwise first — the Fold8's main
    screen is drawn wide, the spec's portrait is tall."""
    rgb, body, screen = samsung_body(skin_dir)
    sx, sy, sw, sh = screen
    if turn:
        h0 = body.shape[0]
        body = np.rot90(body, k=-1)
        rgb = np.rot90(rgb, k=-1)
        sx, sy, sw, sh = h0 - (sy + sh), sx, sh, sw
        screen = (sx, sy, sw, sh)
    # The raw silhouette, keys included (the body mask has them opened
    # away): how far the painted keys stand out.
    raw = ((rgb[..., 2] - rgb[..., 0]) < 12) | (rgb.max(2) < 24)
    x0, y0, x1, y1 = _body_box(body, screen)
    box = body[y0:y1, x0:x1]
    radii = [diagonal_radius(box, c) / dpr for c in ("tl", "tr", "br", "bl")]
    geometry = mask_geometry(skin_dir, (sw, sh), turn=turn)
    screen_radii = [r / dpr for r in geometry["radii"]]  # tl, tr, br, bl
    keys = samsung_buttons(skin_dir, turn=turn)

    def dp(v):
        return v / dpr

    # How far the keys stand out of the body on each side, as the art
    # draws them.
    def art_depth(side, start, end):
        lo, hi = int(start) + 4, int(end) - 4
        if side == "right":
            band = raw[lo:hi, x1:x1 + 40]
            return max((np.where(r)[0].max() + 1 if r.any() else 0)
                       for r in band)
        if side == "left":
            band = raw[lo:hi, max(0, x0 - 40):x0][:, ::-1]
            return max((np.where(r)[0].max() + 1 if r.any() else 0)
                       for r in band)
        if side == "bottom":
            band = raw[y1:y1 + 40, lo:hi].T
            return max((np.where(r)[0].max() + 1 if r.any() else 0)
                       for r in band)
        band = raw[max(0, y0 - 40):y0, lo:hi][::-1].T
        return max((np.where(r)[0].max() + 1 if r.any() else 0)
                   for r in band)

    def proud(side):
        depths = [art_depth(side, a_, b_) for s_, a_, b_, _ in keys
                  if s_ == side]
        return max([0.0] + [dp(d) for d in depths])

    ml, mr, mt, mb = proud("left"), proud("right"), proud("top"), proud("bottom")
    bw, bh = dp(x1 - x0), dp(y1 - y0)
    w, h = bw + ml + mr, bh + mt + mb
    button, rim, face, bezel = template_colors(open_frame["body"])

    def outline(inset):
        return rounded_path(bw - 2 * inset, bh - 2 * inset,
                            [max(0.0, r - inset) for r in radii])

    def at(inset):
        return f' transform="translate({fmt(ml + inset)}, {fmt(mt + inset)})"'

    lines = [f'<svg viewBox="0 0 {fmt(w)} {fmt(h)}">',
             '  <defs><clipPath id="shell">',
             f'    <path d="{outline(0)}"{at(0)}/>',
             '  </clipPath></defs>',
             f'  <g fill="{button}">']
    for side, start, end, _ in keys:
        # Each key tucked 2 under the body, standing as proud as the art.
        depth = {"left": ml, "right": mr, "top": mt, "bottom": mb}[side] + 2
        if side in ("left", "right"):
            x = w - depth if side == "right" else 0
            y = mt + dp(start - y0)
            lines.append(f'    <rect x="{fmt(x)}" y="{fmt(y)}"'
                         f' width="{fmt(depth)}"'
                         f' height="{fmt(dp(end - start))}" rx="1"/>')
        else:
            y = h - depth if side == "bottom" else 0
            x = ml + dp(start - x0)
            lines.append(f'    <rect x="{fmt(x)}" y="{fmt(y)}"'
                         f' width="{fmt(dp(end - start))}"'
                         f' height="{fmt(depth)}" rx="1"/>')
    lines += ['  </g>',
              f'  <path d="{outline(0)}"{at(0)} fill="{rim}"/>',
              f'  <path d="{outline(2)}"{at(2)} fill="{face}"/>',
              '  <g clip-path="url(#shell)">',
              f'    <path d="M {fmt(-h)},0 L {fmt(-0.6 * h)},0 L {fmt(0.12 * h)},'
              f'{fmt(h)} L {fmt(-0.28 * h)},{fmt(h)} Z" fill="#ffffff"'
              ' fill-opacity="0.18"/>',
              '  </g>',
              f'  <path d="{outline(3.5)}"{at(3.5)} fill="{bezel}"/>',
              '</svg>']
    path = rounded_path(dp(sw), dp(sh), screen_radii)
    holes = []
    for a, b, c, d in geometry["holes"]:
        cx, cy = dp((a + c) / 2), dp((b + d) / 2)
        r = dp(max(c - a, d - b) / 2)
        path += " " + pixel.circle_ccw_path(cx, cy, r)
        holes.append((dp(a), dp(b), dp(c), dp(d)))
    return {
        "size": {"width": rounded(w), "height": rounded(h)},
        "screenOffset": {"x": rounded(ml + dp(sx - x0)),
                         "y": rounded(mt + dp(sy - y0))},
        "screenPath": path,
        "body": lines,
    }, (dp(sw), dp(sh)), holes


# --- specs ---------------------------------------------------------------------

def load_measurements():
    return json.load(open(os.path.join(SKILL_DIR, "measurements.json")))


def build_posture(spec, measured, frame, screen_size, cutout_list, open_):
    """One posture's fields: the open posture's go at the spec's top level,
    the closed cover's into `postures.closed`."""
    out = {}
    if not open_:
        out["portraitSize"] = {"width": rounded(screen_size[0]),
                               "height": rounded(screen_size[1])}
        dpr = spec["devicePixelRatio"]
        out["physicalSize"] = {"width": round(screen_size[0] * dpr),
                               "height": round(screen_size[1] * dpr)}
    out["portraitPadding"] = insets(measured["portraitPadding"])
    out["landscapePadding"] = insets(measured["landscapePadding"])
    out["portraitKeyboardHeight"], out["landscapeKeyboardHeight"] = KEYBOARD
    features = [f for f in spec.get("displayFeatures", [])
                if f["type"] in ("fold", "hinge")] if open_ else []
    for c in cutout_list:
        features.append({"bounds": rect(c), "type": "cutout",
                         "state": "unknown"})
    out["displayFeatures"] = features
    out["frame"] = frame
    out["systemUi"] = system_ui(spec["systemUi"], measured)
    return out


ORDER = ["id", "name", "brand", "year", "platform", "kind", "portraitSize",
         "devicePixelRatio", "physicalSize", "portraitPadding",
         "landscapePadding", "portraitKeyboardHeight",
         "landscapeKeyboardHeight", "displayFeatures", "frame", "systemUi",
         "postures"]


def ordered(spec):
    return {k: spec[k] for k in ORDER if k in spec} | \
        {k: v for k, v in spec.items() if k not in ORDER}


def pixel_fold(spec_id, entry, measurements):
    spec = json.load(open(os.path.join(SPECS, f"{spec_id}.json")))
    dpr = spec["devicePixelRatio"]
    roots = pixel.skin_roots([])
    postures = {}
    for posture, skin in (("open", entry["skins"]["open"]),
                          ("closed", entry["skins"]["closed"])):
        skin_dir = pixel.find_skin(skin, roots)
        override = entry.get("resolution", {}).get(posture)
        frame, size = pixel.build_frame(skin_dir, dpr, screen_px=override)
        m = measurements[posture]
        fields = build_posture(spec, m, frame, size, m.get("cutouts", []),
                               posture == "open")
        postures[posture] = fields
    spec.update(postures["open"])
    spec["postures"] = {"halfOpened": {}, "closed": postures["closed"]}
    return spec


def camera_padding(size, holes, bars):
    """Safe areas read off a screen's mask: [bars] (the device's own bar
    insets, `[left, top, right, bottom]` for portrait and landscape) on
    every side, the one nearest each cutout grown to hold it. A camera
    hole sits centred in its bar — Samsung's status bar holds the punch
    hole midway — so that bar is twice the hole's centre from the edge; a
    large cutout (the Flip8 cover's camera rings) takes its edge's inset
    past its far side."""
    w, h = size
    portrait, landscape = list(bars["portrait"]), list(bars["landscape"])
    for left, top, right, bottom in holes:
        d = {"top": top, "bottom": h - bottom, "left": left,
             "right": w - right}
        side = min(d, key=d.get)
        small = max(right - left, bottom - top) / 2 < 20
        centre = {"top": (top + bottom) / 2, "bottom": h - (top + bottom) / 2,
                  "left": (left + right) / 2,
                  "right": w - (left + right) / 2}[side]
        far = {"top": bottom, "bottom": h - top, "left": right,
               "right": w - left}[side]
        reach = 2 * centre if small else far
        i = ("left", "top", "right", "bottom").index(side)
        portrait[i] = max(portrait[i], reach)
        # The package's quarter turn maps portrait top -> landscape left,
        # right -> top, bottom -> right, left -> bottom.
        k = {"top": 0, "right": 1, "bottom": 2, "left": 3}[side]
        landscape[k] = max(landscape[k], reach)
    return portrait, landscape


def main_camera(skin_dir, dpr, size, turn):
    """The inner screen's camera holes from its mask, in the spec's
    portrait (turned a quarter clockwise where the skin is drawn wide),
    centred on the spec's screen where the two sizes differ slightly."""
    alpha = Image.open(os.path.join(skin_dir, "fore_port.png")).size
    geometry = mask_geometry(skin_dir, alpha)
    sw, sh = alpha
    holes = geometry["holes"]
    if turn:
        holes = [(sh - d, a, sh - b, c) for a, b, c, d in holes]
        sw, sh = sh, sw
    dx, dy = (sw / dpr - size[0]) / 2, (sh / dpr - size[1]) / 2
    return [(a / dpr - dx, b / dpr - dy, c / dpr - dx, d / dpr - dy)
            for a, b, c, d in holes]


def samsung_skin(samsung_dir, path):
    """[path] under [samsung_dir] — unpacked there, or still inside the
    `<device>.zip` Samsung's site downloads (unpacked to a temporary
    directory)."""
    unpacked = os.path.join(samsung_dir, path)
    if os.path.isdir(unpacked):
        return unpacked
    import tempfile
    import zipfile
    archive = os.path.join(samsung_dir, path.split("/")[0] + ".zip")
    if not os.path.exists(archive):
        sys.exit(f"error: neither {unpacked} nor {archive} exists — download "
                 "the skin from developer.samsung.com/galaxy-emulator-skin")
    target = tempfile.mkdtemp(prefix="samsung-skin-")
    zipfile.ZipFile(archive).extractall(target)
    return os.path.join(target, path)


def open_buttons(frame, skin_dir, dpr, turn):
    """Redraws the open frame's side buttons where the main skin has them
    (its layout's `buttons`), in the frame's own style: 6-wide keys
    standing 4 proud of the body. The Fold8's main skin is drawn wide, so
    its right-edge keys turn to the bottom edge of the spec's portrait —
    the frame then grows 4 at the bottom to show them proud."""
    _, (sw, sh), (sx, sy) = samsung_layout(skin_dir)
    body = frame["body"]
    text = "\n".join(body)
    shell = re.search(r'<clipPath id="shell">\s*<path d="([^"]+)"', text).group(1)
    pairs = [tuple(map(float, m)) for m in
             re.findall(r"(-?[\d.]+),(-?[\d.]+)", shell)]
    body_w = max(x for x, _ in pairs) + 4  # the keys' margin
    body_h = max(y for _, y in pairs)
    ox, oy = frame["screenOffset"]["x"], frame["screenOffset"]["y"]
    fill = re.search(r'<g fill="(#[0-9a-f]{6})">', text).group(1)
    rects = []
    for x, top, bottom in samsung_buttons(skin_dir):
        right = x > sx + sw / 2
        length = (bottom - top) / dpr
        if turn and right:
            left = ox + (sh - (bottom - sy)) / dpr
            rects.append(f'    <rect x="{fmt(left)}" y="{fmt(body_h - 2)}"'
                         f' width="{fmt(length)}" height="6" rx="2"/>')
        else:
            kx = body_w - 6 if right else 0
            rects.append(f'    <rect x="{fmt(kx)}" y="{fmt(oy + (top - sy) / dpr)}"'
                         f' width="6" height="{fmt(length)}" rx="2"/>')
    height = body_h + 4 if turn else body_h
    new = []
    skip = False
    for line in body:
        if line.startswith("<svg viewBox="):
            line = f'<svg viewBox="0 0 {fmt(body_w)} {fmt(height)}">'
        if line.strip().startswith(f'<g fill="{fill}">'):
            new.append(line)
            new.extend(rects)
            skip = True
            continue
        if skip:
            if line.strip() == "</g>":
                skip = False
                new.append(line)
            continue
        new.append(line)
    frame["body"] = new
    frame["size"] = {"width": fmt_json(body_w), "height": fmt_json(height)}


def samsung_fold(spec_id, entry, measurements, samsung_dir):
    """Both Samsung screens from their skins — body, corners, keys, screen
    outline and camera — in the catalog's Samsung frame style, keeping the
    spec's bar insets (`bars`), grown to hold each camera; the half-open
    posture is the open screen."""
    spec = json.load(open(os.path.join(SPECS, f"{spec_id}.json")))
    dpr = spec["devicePixelRatio"]
    bars = entry["bars"]

    # The open screen, drawn from the main skin like the cover: its body,
    # corners, keys and camera as Samsung's art has them.
    frame, size, holes = samsung_cover_frame(
        samsung_skin(samsung_dir, entry["main"]), dpr, spec["frame"],
        turn=entry.get("turn", False))
    want = (spec["portraitSize"]["width"], spec["portraitSize"]["height"])
    if any(abs(a - b) > 0.02 for a, b in zip(size, want)):
        sys.exit(f"error: {spec_id} main skin screen {size} != spec {want}")
    portrait, landscape = camera_padding(size, holes, bars)
    spec["portraitPadding"] = insets(portrait)
    spec["landscapePadding"] = insets(landscape)
    spec["displayFeatures"] = [
        f for f in spec["displayFeatures"] if f["type"] != "cutout"
    ] + [{"bounds": rect(c), "type": "cutout", "state": "unknown"}
         for c in holes]
    spec["frame"] = frame

    skin_dir = samsung_skin(samsung_dir, entry["cover"])
    frame, size, holes = samsung_cover_frame(skin_dir, dpr, spec["frame"])
    portrait, landscape = camera_padding(size, holes, bars)
    closed = {
        "portraitSize": {"width": rounded(size[0]), "height": rounded(size[1])},
        "physicalSize": {"width": round(size[0] * dpr),
                         "height": round(size[1] * dpr)},
        "portraitPadding": insets(portrait),
        "landscapePadding": insets(landscape),
        "portraitKeyboardHeight": spec["portraitKeyboardHeight"],
        "landscapeKeyboardHeight": spec["landscapeKeyboardHeight"],
        "displayFeatures": [{"bounds": rect(c), "type": "cutout",
                             "state": "unknown"} for c in holes],
        "frame": frame,
    }
    spec["postures"] = {"halfOpened": {}, "closed": closed}
    return spec


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ids", nargs="*")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--samsung-dir",
                        default=os.path.expanduser("~/Downloads"))
    args = parser.parse_args()
    measurements = load_measurements()
    for spec_id, entry in measurements.items():
        if spec_id.startswith("_") or (args.ids and spec_id not in args.ids):
            continue
        if entry["source"] == "pixel":
            spec = pixel_fold(spec_id, entry, entry["postures"])
        else:
            spec = samsung_fold(spec_id, entry, measurements,
                                args.samsung_dir)
        spec = ordered(spec)
        path = os.path.join(SPECS, f"{spec_id}.json")
        # Keep the file's own indentation (the Samsung specs use one space).
        second = open(path).read().split("\n")[1]
        indent = len(second) - len(second.lstrip(" ")) or 2
        text = json.dumps(spec, indent=indent, ensure_ascii=False) + "\n"
        print(f"{spec_id}: {'would write' if args.dry_run else 'wrote'} {path}")
        if not args.dry_run:
            open(path, "w").write(text)


if __name__ == "__main__":
    main()
