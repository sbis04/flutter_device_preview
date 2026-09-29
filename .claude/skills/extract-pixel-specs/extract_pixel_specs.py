#!/usr/bin/env python3
"""Rebuild the Google Pixel specs in device_specs/ from the official Android
emulator device skins and a live emulator probe.

See SKILL.md next to this file for the sources and their semantics.
Requires Pillow (`pip install pillow`). Usage:

    python extract_pixel_specs.py [--dry-run] [--no-probe]
                                  [--skins-dir DIR ...] [ids...]
    python extract_pixel_specs.py --preview pixel_6_pro [--probe-device pixel_6]
"""

import argparse
import glob
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time

from PIL import Image

# Catalog id -> how to derive it from the emulator.
#   skin:       skin directory name (official artwork)
#   avd_device: `avdmanager list device` id for the metrics probe
#   donor:      True when the skin belongs to another device that shares the
#               panel — frame artwork only, keep hand-authored metrics
#   skip:       reason this device cannot be derived yet
DEVICES = {
    "google-pixel-9": {"skin": "pixel_9", "avd_device": "pixel_9"},
    # Pixel 10 has its own skin but no AVD definition yet; it shares the
    # Pixel 9's 1080x2424 @2.625 panel, so that profile probes its metrics.
    "google-pixel-10": {"skin": "pixel_10", "avd_device": "pixel_9"},
    # Foldables have a skin and a measured layout per posture: see the
    # extract-foldable-specs skill, which rebuilds them from both.
    "google-pixel-10-pro-fold": {"skip": "a foldable — rebuilt by "
                                         "extract-foldable-specs"},
    # Android Studio defines the Pixel 9 Pro XL (sdklib's nexus.xml:
    # 1344x2992, xxhdpi -> 448x997.33 @3) but the command-line tools do not:
    # the probe AVD is a stand-in profile with that official panel written
    # into its config. Its spec was first built without a probe (`donor`):
    # no bootable system image was installed, so the bar insets are the
    # Pixel 9's Android 16 ones (54 dp status bar, 24 dp gesture bar). Drop
    # `donor` to probe it once an image boots.
    "google-pixel-9-pro-xl": {"skin": "pixel_9_pro_xl",
                              "avd_device": "pixel_7_pro",
                              "hardware": {"hw.lcd.width": 1344,
                                           "hw.lcd.height": 2992,
                                           "hw.lcd.density": 480},
                              "donor": True},
}

SKILL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(SKILL_DIR)))
SPECS = os.path.join(REPO, "device_specs")

SOLID_ALPHA = 250  # below this it's the drop shadow around the body art
OPAQUE = 128


def fmt(value):
    rounded = round(value, 2)
    if rounded == int(rounded):
        return str(int(rounded))
    return f"{rounded:g}"


def fmt_json(value):
    return int(value) if value == int(value) else round(value, 2)


# --- skin discovery and parsing ----------------------------------------------

def sdk_root():
    for candidate in (os.environ.get("ANDROID_HOME"),
                      os.environ.get("ANDROID_SDK_ROOT"),
                      os.path.expanduser("~/Library/Android/sdk"),
                      os.path.expanduser("~/Android/Sdk")):
        if candidate and os.path.isdir(candidate):
            return candidate
    return None


def skin_roots(extra):
    roots = list(extra)
    sdk = sdk_root()
    if sdk:
        roots.append(os.path.join(sdk, "skins"))
    for app in sorted(glob.glob("/Applications/Android Studio*.app")):
        roots.append(os.path.join(
            app, "Contents/plugins/android/resources/device-art-resources"))
    return [r for r in roots if os.path.isdir(r)]


def find_skin(name, roots):
    for root in roots:
        path = os.path.join(root, name)
        if os.path.isfile(os.path.join(path, "layout")):
            return path
    return None


def available_skins(roots):
    found = set()
    for root in roots:
        for path in glob.glob(os.path.join(root, "*", "layout")):
            found.add(os.path.basename(os.path.dirname(path)))
    return sorted(found)


def parse_layout(path):
    """The emulator skin `layout` format: line-oriented `key value` pairs
    and `key { ... }` blocks."""
    root, stack = {}, []
    node = root
    for raw in open(path):
        line = raw.strip()
        if not line:
            continue
        if line.endswith("{"):
            child = {}
            node[line[:-1].strip()] = child
            stack.append(node)
            node = child
        elif line == "}":
            node = stack.pop()
        else:
            key, _, value = line.partition(" ")
            node[key] = value.strip()
    return root


def skin_geometry(skin_dir):
    layout = parse_layout(os.path.join(skin_dir, "layout"))
    display = layout["parts"]["device"]["display"]
    # Unfolded foldable skins call their only layout "landscape".
    layouts = layout["layouts"]
    chosen = layouts.get("portrait") or next(
        part for part in layouts.values() if isinstance(part, dict))
    device_offset = None
    for key, part in chosen.items():
        if isinstance(part, dict) and part.get("name") == "device":
            device_offset = (int(part["x"]), int(part["y"]))
    if device_offset is None:
        sys.exit(f"error: no device part in {skin_dir}/layout")
    images = layout["parts"]["portrait"]
    return {
        "screen_px": (int(display["width"]), int(display["height"])),
        "screen_pos": (device_offset[0] + int(display.get("x", 0)),
                       device_offset[1] + int(display.get("y", 0))),
        # Newer layouts declare the screen corner radius themselves.
        "corner_radius": int(display["corner_radius"])
        if "corner_radius" in display else None,
        "back": os.path.join(skin_dir, images["background"]["image"]),
        "mask": os.path.join(skin_dir, images["foreground"]["mask"])
        if "foreground" in images and "mask" in images["foreground"]
        else None,
    }


# --- raster analysis ---------------------------------------------------------

def median_color(pixels):
    channels = list(zip(*[p[:3] for p in pixels]))
    return tuple(sorted(c)[len(c) // 2] for c in channels)


def hex_color(rgb):
    return "#%02x%02x%02x" % rgb


def analyze_back(back_path, screen_pos, screen_px):
    """Body bounds (alpha >= SOLID_ALPHA), outer corner radius, and two
    quantized ring colors from the photorealistic body art: the metallic
    edge just inside the silhouette, and the front-face bezel sampled 75%
    of the way from the body edge to the screen edge."""
    image = Image.open(back_path).convert("RGBA")
    alpha = image.getchannel("A")
    solid = alpha.point(lambda v: 255 if v >= SOLID_ALPHA else 0)
    bounds = solid.getbbox()
    if bounds is None:
        sys.exit(f"error: fully transparent body art {back_path}")
    x0, y0, x1, y1 = bounds
    radius = next(
        (i for i in range(x1 - x0)
         if solid.getpixel((x0 + i, y0)) and solid.getpixel((x0 + i, y0 + 1))),
        0)
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    edge = median_color([
        image.getpixel((x0 + 1, cy)), image.getpixel((x1 - 2, cy)),
        image.getpixel((cx, y0 + 1)), image.getpixel((cx, y1 - 2)),
    ])
    sx, sy = screen_pos
    face = median_color([
        image.getpixel((x0 + max(1, round((sx - x0) * 0.75)), cy)),
        image.getpixel((x1 - max(2, round((x1 - sx - screen_px[0]) * 0.75)),
                        cy)),
        image.getpixel((cx, y0 + max(1, round((sy - y0) * 0.75)))),
        image.getpixel((cx, y1 - max(2, round((y1 - sy - screen_px[1])
                                              * 0.75)))),
    ])
    body, keys = body_and_keys(solid, image)
    return {"bounds": bounds, "radius": radius, "edge": edge, "face": face,
            "body": body, "keys": keys}


def body_and_keys(solid, image):
    """The body box without its side keys, and the keys: the art paints the
    power key and the volume rocker standing proud of the body's side, so
    each side's typical extent (the median over the middle rows) is the
    body, and every run of rows reaching past it by a few pixels is a key
    — (side, top, bottom, outer edge, color) in canvas px."""
    import numpy as np
    m = np.asarray(solid) > 0
    rows = np.where(m.any(1))[0]
    y0, y1 = rows.min(), rows.max() + 1
    band = range(y0 + (y1 - y0) // 10, y1 - (y1 - y0) // 10)
    left = np.array([np.argmax(m[y]) for y in range(m.shape[0])])
    right = np.array([m.shape[1] - 1 - np.argmax(m[y, ::-1])
                      for y in range(m.shape[0])])
    body_left = int(np.median([left[y] for y in band]))
    body_right = int(np.median([right[y] for y in band])) + 1
    keys = []
    for side, reach in (("right", right - (body_right - 1)),
                        ("left", body_left - left)):
        start = None
        for y in range(y0, y1 + 1):
            proud = y < y1 and m[y].any() and reach[y] > 3
            if proud and start is None:
                start = y
            elif not proud and start is not None:
                if y - start > 20:
                    outer = (int(right[start:y].max()) + 1 if side == "right"
                             else int(left[start:y].min()))
                    x = (body_right + outer) // 2 if side == "right" \
                        else (outer + body_left) // 2
                    color = median_color([image.getpixel((x, yy)) for yy in
                                          range(start + 4, y - 4, 7)])
                    keys.append((side, start, y, outer, color))
                start = None
    return (body_left, int(y0), body_right, int(y1)), keys


def fit_corner_radius(grid, w):
    """Least-squares circle through the top-left overlay's inner edge —
    per row, the first pixel the overlay leaves uncovered — or None when
    the edge is no arc (residual over a pixel) or too short to fit."""
    points = []
    for y, row in enumerate(grid[:w // 2]):
        x = 0
        while x < w // 2 and row[x]:
            x += 1
        if x >= w // 2:
            continue
        if x <= 1 and points:
            break  # past the arc: the straight edge
        if x > 1:
            points.append((float(x), float(y)))
    if len(points) < 12:
        return None
    # Algebraic fit: x² + y² = 2ax + 2by + c, solved by normal equations.
    sums = [[0.0] * 3 for _ in range(3)]
    rhs = [0.0] * 3
    for x, y in points:
        row = (2 * x, 2 * y, 1.0)
        target = x * x + y * y
        for i in range(3):
            rhs[i] += row[i] * target
            for j in range(3):
                sums[i][j] += row[i] * row[j]
    try:
        a, b, c = solve3(sums, rhs)
    except ZeroDivisionError:
        return None
    r = math.sqrt(max(0.0, c + a * a + b * b))
    residual = max(abs(math.hypot(x - a, y - b) - r) for x, y in points)
    return round(r) if r > 0 and residual <= 1.5 else None


def solve3(m, v):
    """Gaussian elimination for a 3×3 system."""
    m = [row[:] + [v[i]] for i, row in enumerate(m)]
    for col in range(3):
        pivot = max(range(col, 3), key=lambda r: abs(m[r][col]))
        if abs(m[pivot][col]) < 1e-12:
            raise ZeroDivisionError
        m[col], m[pivot] = m[pivot], m[col]
        for r in range(3):
            if r != col:
                f = m[r][col] / m[col][col]
                m[r] = [a - f * b for a, b in zip(m[r], m[col])]
    return [m[i][3] / m[i][i] for i in range(3)]


def analyze_mask(mask_path, screen_px):
    """Screen corner radius and camera punch hole from the mask overlay:
    opaque pixels are what covers the screen. Corner overlays touch the
    screen edges (row 0); a punch hole is an island that touches none, so
    connected components in the top strip separate the two — this also
    finds holes sitting near a corner, like a foldable's inner camera."""
    if mask_path is None or not os.path.exists(mask_path):
        return {"radius": 0, "hole": None}
    alpha = Image.open(mask_path).convert("RGBA").getchannel("A")
    w, h = alpha.size
    strip_h = min(h, max(200, h // 6))
    grid = [[alpha.getpixel((x, y)) >= OPAQUE for x in range(w)]
            for y in range(strip_h)]

    # The corner radius: the circle the top-left overlay's inner edge
    # traces. This is what the emulator window shows — its `corner_radius`
    # in the layout is what the OS is told for insets and is smaller on
    # the Pixels (87 px vs the ~137 px the Pixel 9's mask draws).
    radius = fit_corner_radius(grid, w)
    if radius is None:
        # No usable arc: fall back to the extent of the overlay along
        # row 0 (tolerating a few transparent antialiased pixels first).
        radius = 0
        x = 0
        while x < w // 2 and not grid[0][x]:
            x += 1
        if x < 8:
            while x < w // 2 and grid[0][x]:
                x += 1
            radius = x

    seen = [[False] * w for _ in range(strip_h)]
    hole = None
    for y0 in range(strip_h):
        for x0 in range(w):
            if not grid[y0][x0] or seen[y0][x0]:
                continue
            stack, pixels, touches_border = [(x0, y0)], [], False
            seen[y0][x0] = True
            while stack:
                px, py = stack.pop()
                pixels.append((px, py))
                if py == 0 or py == strip_h - 1:
                    touches_border = True
                for nx, ny in ((px - 1, py), (px + 1, py),
                               (px, py - 1), (px, py + 1)):
                    if 0 <= nx < w and 0 <= ny < strip_h and \
                            grid[ny][nx] and not seen[ny][nx]:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            if touches_border:
                continue  # corner or edge overlay, not a hole
            xs = [p[0] for p in pixels]
            ys = [p[1] for p in pixels]
            candidate = {"cx": (min(xs) + max(xs) + 1) / 2,
                         "cy": (min(ys) + max(ys) + 1) / 2,
                         "r": max(max(xs) - min(xs),
                                  max(ys) - min(ys)) / 2 + 0.5}
            if hole is None or candidate["r"] > hole["r"]:
                hole = candidate
    return {"radius": radius, "hole": hole}


# --- frame construction ------------------------------------------------------

def rounded_rect_path(w, h, r):
    return (f"M {fmt(r)},0 H {fmt(w - r)} "
            f"A {fmt(r)},{fmt(r)} 0 0 1 {fmt(w)},{fmt(r)} V {fmt(h - r)} "
            f"A {fmt(r)},{fmt(r)} 0 0 1 {fmt(w - r)},{fmt(h)} H {fmt(r)} "
            f"A {fmt(r)},{fmt(r)} 0 0 1 0,{fmt(h - r)} V {fmt(r)} "
            f"A {fmt(r)},{fmt(r)} 0 0 1 {fmt(r)},0 Z")


def circle_ccw_path(cx, cy, r):
    return (f"M {fmt(cx)},{fmt(cy - r)} "
            f"A {fmt(r)},{fmt(r)} 0 1 0 {fmt(cx)},{fmt(cy + r)} "
            f"A {fmt(r)},{fmt(r)} 0 1 0 {fmt(cx)},{fmt(cy - r)} Z")


def build_frame(skin_dir, dpr):
    geometry = skin_geometry(skin_dir)
    back = analyze_back(geometry["back"], geometry["screen_pos"],
                        geometry["screen_px"])
    mask = analyze_mask(geometry["mask"], geometry["screen_px"])
    if not mask["radius"] and geometry["corner_radius"] is not None:
        mask["radius"] = geometry["corner_radius"]
    bx0, by0, bx1, by1 = back["bounds"]
    sw, sh = geometry["screen_px"]
    sx, sy = geometry["screen_pos"]

    def dp(v):
        return v / dpr

    body_w, body_h = dp(bx1 - bx0), dp(by1 - by0)
    offset = (dp(sx - bx0), dp(sy - by0))
    if offset[0] < 0 or offset[1] < 0 or \
            offset[0] + dp(sw) > body_w or offset[1] + dp(sh) > body_h:
        sys.exit(f"error: screen escapes the body in {skin_dir}")

    path = rounded_rect_path(dp(sw), dp(sh), dp(mask["radius"]))
    if mask["hole"]:
        hole = mask["hole"]
        path += " " + circle_ccw_path(dp(hole["cx"]), dp(hole["cy"]),
                                      dp(hole["r"]))

    radius = dp(back["radius"])
    # The body proper, inside the box its side keys widen.
    kx0, _, kx1, _ = back["body"]
    left, width = dp(kx0 - bx0), dp(kx1 - kx0)
    body = [f'<svg viewBox="0 0 {fmt(body_w)} {fmt(body_h)}">']
    for side, top, bottom, outer, color in back["keys"]:
        # Each key tucked 1 dp under the body's edge, standing as proud as
        # the art draws it.
        if side == "right":
            x, w = dp(kx1 - bx0) - 1, dp(outer - kx1) + 1
        else:
            x, w = dp(outer - bx0), dp(kx0 - outer) + 1
        body.append(f'  <rect x="{fmt(x)}" y="{fmt(dp(top - by0))}"'
                    f' width="{fmt(w)}" height="{fmt(dp(bottom - top))}"'
                    f' rx="{fmt(min(1.0, w / 2))}" fill="{hex_color(color)}"/>')
    body += [
        f'  <rect x="{fmt(left)}" y="0" width="{fmt(width)}"'
        f' height="{fmt(body_h)}" rx="{fmt(radius)}"'
        f' fill="{hex_color(back["edge"])}"/>',
        f'  <rect x="{fmt(left + 1)}" y="1" width="{fmt(width - 2)}"'
        f' height="{fmt(body_h - 2)}" rx="{fmt(max(0.0, radius - 1))}"'
        f' fill="{hex_color(back["face"])}"/>',
        "</svg>",
    ]
    return {
        "size": {"width": fmt_json(body_w), "height": fmt_json(body_h)},
        "screenOffset": {"x": fmt_json(offset[0]), "y": fmt_json(offset[1])},
        "screenPath": path,
        "body": body,
    }, (dp(sw), dp(sh))


# --- live metrics probe ------------------------------------------------------

class EmulatorProbe:
    def __init__(self):
        self.sdk = sdk_root()
        if self.sdk is None:
            sys.exit("error: no Android SDK found (set ANDROID_HOME)")
        self.avdmanager = self._tool("cmdline-tools/latest/bin/avdmanager")
        self.emulator = self._tool("emulator/emulator")
        self.adb = self._tool("platform-tools/adb", which="adb")
        self.cache = {}  # avd_device -> metrics (panel donors share a boot)

    def _tool(self, relative, which=None):
        path = os.path.join(self.sdk, relative)
        if os.path.exists(path):
            return path
        if which:
            found = shutil.which(which)
            if found:
                return found
        sys.exit(f"error: missing Android tool: {relative}")

    def system_image(self):
        images = []
        for path in glob.glob(os.path.join(self.sdk, "system-images",
                                           "android-*", "*", "*")):
            api = int(path.split("android-")[1].split(os.sep)[0])
            parts = path.split(os.sep)
            images.append((api, f"system-images;android-{api};"
                                f"{parts[-2]};{parts[-1]}"))
        if not images:
            sys.exit("error: no emulator system images installed")
        return max(images)[1]

    def _write_avd(self):
        image = self.system_image()  # system-images;android-N;tag;abi
        _, platform, tag, abi = image.split(";")
        avd_root = os.path.expanduser("~/.android/avd")
        avd_dir = os.path.join(avd_root, "specprobe-tmp.avd")
        os.makedirs(avd_dir, exist_ok=True)
        open(os.path.join(avd_root, "specprobe-tmp.ini"), "w").write(
            f"avd.ini.encoding=UTF-8\npath={avd_dir}\n"
            f"path.rel=avd/specprobe-tmp.avd\ntarget={platform}\n")
        open(os.path.join(avd_dir, "config.ini"), "w").write("\n".join([
            "avd.ini.encoding=UTF-8",
            f"abi.type={abi}",
            f"hw.cpu.arch={'arm64' if 'arm64' in abi else 'x86_64'}",
            f"image.sysdir.1=system-images/{platform}/{tag}/{abi}/",
            f"tag.id={tag}",
            f"PlayStore.enabled={'true' if 'playstore' in tag else 'false'}",
            "hw.ramSize=2048",
            "disk.dataPartition.size=6G",
            "hw.keyboard=yes",
            "hw.initialOrientation=portrait",
            "hw.gpu.enabled=yes",
            "hw.gpu.mode=auto",
            "showDeviceFrame=no",
        ]) + "\n")

    def shell(self, *args, timeout=60):
        return subprocess.run([self.adb, "shell", *args], capture_output=True,
                              text=True, timeout=timeout).stdout

    def bar_insets(self, dpr, wait=True):
        """Bar insets from `dumpsys window displays` — the only section
        that still lists InsetsSource frames on current APIs.

        SystemUI registers the bar sources noticeably after
        `sys.boot_completed`, and their first frames are transitional (a
        default-height status bar that later grows, zero-area navigation
        bars) — so poll until both bars report non-degenerate frames that
        are identical on two consecutive reads.
        """
        deadline = time.time() + (120 if wait else 0)
        pattern = (r"InsetsSource.*?type=(?:ITYPE_)?(STATUS_BAR|statusBars|"
                   r"NAVIGATION_BAR|navigationBars)\b.*?"
                   r"frame=\[(\d+),(\d+)\]\[(\d+),(\d+)\]")
        previous = None
        while True:
            dump = subprocess.run(
                [self.adb, "shell", "dumpsys", "window", "displays"],
                capture_output=True, text=True, timeout=60).stdout
            display = re.search(
                r"mDisplayFrame=Rect\((\d+), (\d+) - (\d+), (\d+)", dump)
            bars = {}
            for kind, l, t, r, b in re.findall(pattern, dump):
                key = kind.lower().replace("_", "").replace("bars", "bar")
                frame = (int(l), int(t), int(r), int(b))
                if frame[2] > frame[0] and frame[3] > frame[1]:
                    bars.setdefault(key, frame)
            ready = display and {"statusbar", "navigationbar"} <= set(bars)
            if ready and bars == previous:
                break
            if time.time() > deadline:
                if ready:
                    break  # never went quiet; take the last reading
                sys.exit("error: system bars never appeared in "
                         f"dumpsys window displays (saw {sorted(bars)})")
            previous = bars if ready else None
            time.sleep(3)
        dw = int(display.group(3)) - int(display.group(1))
        dh = int(display.group(4)) - int(display.group(2))
        insets = {"left": 0, "top": 0, "right": 0, "bottom": 0}
        for l, t, r, b in bars.values():
            if t == 0 and b < dh:
                insets["top"] = max(insets["top"], round((b - t) / dpr))
            elif b == dh and t > 0:
                insets["bottom"] = max(insets["bottom"], round((b - t) / dpr))
            elif l == 0 and r < dw:
                insets["left"] = max(insets["left"], round((r - l) / dpr))
            elif r == dw and l > 0:
                insets["right"] = max(insets["right"], round((r - l) / dpr))
        return insets, dw > dh

    def probe(self, avd_device, hardware=None):
        key = (avd_device, tuple(sorted((hardware or {}).items())))
        if key in self.cache:
            return self.cache[key]
        metrics = self._probe(avd_device, hardware or {})
        self.cache[key] = metrics
        return metrics

    def _probe(self, avd_device, hardware):
        create = subprocess.run(
            [self.avdmanager, "create", "avd", "-n", "specprobe-tmp",
             "-k", self.system_image(), "-d", avd_device, "--force"],
            input="no\n", capture_output=True, text=True)
        if create.returncode != 0:
            if not hardware:
                sys.exit(f"error: avdmanager create failed for "
                         f"{avd_device!r}:\n{create.stderr.strip()}")
            # Command-line tools older than the installed system images
            # ("only understands SDK XML versions up to 3") cannot create an
            # AVD at all — but an AVD is two small files, and with the
            # panel given explicitly nothing else is needed from a profile.
            print(f"  avdmanager unusable ({create.stderr.strip().splitlines()[0]}"
                  f"); writing the probe AVD directly")
            self._write_avd()
        if hardware:
            # The official panel of a device the local tools do not define.
            config = os.path.join(os.path.expanduser("~/.android/avd"),
                                  "specprobe-tmp.avd", "config.ini")
            lines = [line for line in open(config).read().splitlines()
                     if line.split("=", 1)[0].strip() not in hardware]
            lines += [f"{k}={v}" for k, v in hardware.items()]
            open(config, "w").write("\n".join(lines) + "\n")
        process = subprocess.Popen(
            [self.emulator, "-avd", "specprobe-tmp", "-no-window", "-no-audio",
             "-no-boot-anim", "-no-snapshot"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.time() + 300
            while time.time() < deadline:
                if self.shell("getprop", "sys.boot_completed").strip() == "1":
                    break
                time.sleep(3)
            else:
                sys.exit("error: emulator never finished booting")
            # SystemUI keeps reconfiguring (status bar height included) for
            # a while after boot; give it a flat grace period before the
            # stability-polled reads.
            time.sleep(30)
            size = re.search(r"(\d+)x(\d+)",
                             self.shell("wm", "size"))
            density = re.search(r"density: (\d+)",
                                self.shell("wm", "density"))
            if not size or not density:
                sys.exit("error: wm size/density unreadable")
            dpr = int(density.group(1)) / 160
            portrait, landscape_now = self.bar_insets(dpr)
            if landscape_now:
                sys.exit("error: display started in landscape unexpectedly")
            # Rotation only applies with a rotatable foreground app.
            self.shell("am", "start", "-a", "android.settings.SETTINGS")
            time.sleep(3)
            self.shell("cmd", "window", "user-rotation", "lock", "1")
            landscape = None
            for _ in range(10):
                time.sleep(2)
                landscape, is_landscape = self.bar_insets(dpr)
                if is_landscape:
                    break
            else:
                sys.exit("error: emulator never rotated to landscape")
            return {
                "width": int(size.group(1)) / dpr,
                "height": int(size.group(2)) / dpr,
                "dpr": dpr,
                "portrait": portrait,
                "landscape": landscape,
            }
        finally:
            subprocess.run([self.adb, "emu", "kill"], capture_output=True)
            process.wait(timeout=30)
            subprocess.run([self.avdmanager, "delete", "avd", "-n",
                            "specprobe-tmp"], capture_output=True)
            avd_root = os.path.expanduser("~/.android/avd")
            shutil.rmtree(os.path.join(avd_root, "specprobe-tmp.avd"),
                          ignore_errors=True)
            if os.path.exists(os.path.join(avd_root, "specprobe-tmp.ini")):
                os.remove(os.path.join(avd_root, "specprobe-tmp.ini"))


# --- spec update -------------------------------------------------------------

def merge_metrics(spec, metrics):
    changes = []

    def assign(key, value):
        if spec.get(key) != value:
            changes.append(f"{key}: {spec.get(key)} -> {value}")
        spec[key] = value

    assign("portraitSize", {"width": fmt_json(metrics["width"]),
                            "height": fmt_json(metrics["height"])})
    assign("devicePixelRatio", float(metrics["dpr"]))
    for key, values in (("portraitPadding", metrics["portrait"]),
                        ("landscapePadding", metrics["landscape"])):
        assign(key, {side: fmt_json(values[side])
                     for side in ("left", "top", "right", "bottom")})
    for change in changes:
        print(f"  {change}")


def update_spec(spec_id, mapping, roots, probe, dry_run):
    if "skip" in mapping:
        print(f"{spec_id}: skipped — {mapping['skip']}")
        return
    spec_path = os.path.join(SPECS, f"{spec_id}.json")
    original = open(spec_path).read()
    spec = json.loads(original)

    skin_dir = find_skin(mapping["skin"], roots)
    if skin_dir is None:
        print(f"{spec_id}: skin {mapping['skin']!r} not installed — skipped.\n"
              f"  available: {', '.join(available_skins(roots)) or 'none'}\n"
              f"  (a newer Android Studio ships newer Pixel skins)")
        return
    donor = mapping.get("donor", False)
    print(f"{spec_id} (skin {mapping['skin']}"
          f"{', donor' if donor else ''}"
          f"{', probed' if probe and not donor else ''})")

    if probe is not None and not donor:
        metrics = probe.probe(mapping["avd_device"], mapping.get("hardware"))
        size = spec["portraitSize"]
        mismatched = abs(metrics["width"] - size["width"]) > 1 or \
            abs(metrics["height"] - size["height"]) > 1
        if mismatched and mapping.get("soft_probe"):
            print(f"  probe reported {metrics['width']:g}x"
                  f"{metrics['height']:g} (another posture/display?) — "
                  "keeping the spec's metrics")
        elif mismatched:
            sys.exit(f"error: probe reported {metrics['width']:g}x"
                     f"{metrics['height']:g} but {spec_id} is "
                     f"{size['width']}x{size['height']} — fix the mapping")
        else:
            merge_metrics(spec, metrics)

    dpr = spec["devicePixelRatio"]
    frame, screen_dp = build_frame(skin_dir, dpr)
    size = spec["portraitSize"]
    # Specs may carry Android's rounded dp (412) where px/dpr is fractional
    # (411.43) — tolerate sub-dp drift, refuse anything larger.
    if abs(screen_dp[0] - size["width"]) > 1 or \
            abs(screen_dp[1] - size["height"]) > 1:
        sys.exit(f"error: {spec_id} is {size['width']}x{size['height']} but "
                 f"the skin display is {screen_dp[0]:g}x{screen_dp[1]:g} dp — "
                 "fix the mapping")
    spec["frame"] = frame

    print(f"  frame: body {frame['size']['width']}x{frame['size']['height']}"
          f" offset {frame['screenOffset']['x']},{frame['screenOffset']['y']}")
    if not dry_run:
        text = json.dumps(spec, indent=2)
        if original.endswith("\n"):
            text += "\n"
        open(spec_path, "w").write(text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ids", nargs="*", default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-probe", action="store_true")
    parser.add_argument("--skins-dir", action="append", default=[])
    parser.add_argument("--preview", metavar="SKIN",
                        help="analyze any available skin without touching "
                             "specs")
    parser.add_argument("--probe-device", metavar="ID",
                        help="with --preview: also probe this AVD device "
                             "profile")
    args = parser.parse_args()
    roots = skin_roots(args.skins_dir)
    print(f"skin roots: {', '.join(roots) or 'none'}")

    if args.preview:
        skin_dir = find_skin(args.preview, roots)
        if skin_dir is None:
            sys.exit(f"error: skin {args.preview!r} not found; available: "
                     f"{', '.join(available_skins(roots)) or 'none'}")
        dpr = 2.625
        if args.probe_device:
            metrics = EmulatorProbe().probe(args.probe_device)
            dpr = metrics["dpr"]
            print(json.dumps(metrics, indent=2))
        frame, screen_dp = build_frame(skin_dir, dpr)
        print(f"screen {fmt(screen_dp[0])}x{fmt(screen_dp[1])} dp @ {dpr}")
        print(json.dumps(frame, indent=2))
        return

    probe = None
    ids = args.ids or sorted(DEVICES)
    if not args.no_probe and any(
            "skip" not in DEVICES[i] and not DEVICES[i].get("donor")
            and find_skin(DEVICES[i]["skin"], roots) for i in ids):
        probe = EmulatorProbe()
    for spec_id in ids:
        update_spec(spec_id, DEVICES[spec_id], roots, probe, args.dry_run)


if __name__ == "__main__":
    main()
