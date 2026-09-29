---
name: extract-foldable-specs
description: Rebuild the half-open and closed postures (and the Pixel fold's open posture) of the Android foldables in device_specs/ — Pixel 10 Pro Fold from Google's emulator skins plus measurements on its emulator, Galaxy Z Fold8 / Fold8 Ultra / Flip8 covers from Samsung's official emulator skins. Use when a foldable's postures, cover screen, cutout or status bar layout need to be (re)derived.
---

# Android foldables → `postures`

`extract_foldable_specs.py` writes the `postures` of the Android foldables
(`halfOpened`, `closed`; the top level is the open posture), reading:

- **`measurements.json`** (next to the script) — what each device's
  emulator reported, per posture, and where Samsung's skins live;
- **the official emulator skins** — frames, screen outlines, cameras.

```sh
python3 .claude/skills/extract-foldable-specs/extract_foldable_specs.py \
  --samsung-dir ~/Downloads          # where Samsung's skin zips (or their
                                     # unpacked folders) are
# [ids...] limits it to some specs; --dry-run writes nothing
```

Then the usual pipeline: `dart run tool/generate_presets.dart` in
`device_preview`, `dart run tool/generate_device_catalog.dart` in the
extension, both test suites, the extension bundle and the docs demo.

## Pixel 10 Pro Fold — measured on its emulator

Android Studio ships the AVD (`hw.device.name=pixel_10_pro_fold`, image
`android-37.2 google_apis_playstore_ps16k`). Its name is what turns on the
guest overlays `com.android.internal.emulation.pixel_10_pro_fold` /
`com.android.systemui.emulation.pixel_10_pro_fold` — the device states and
the cutouts. A hand-made AVD with another name boots with only a `DEFAULT`
state and no cutout, so measure on Android Studio's.

1. Install the probe: `metrics_probe.dart` (next to this file) prints a
   `METRICS {…}` JSON line of `MediaQuery` — size, padding, view padding,
   gesture insets, display features — on every change. Copy it into
   `device_preview/example/lib/`, `flutter build apk --debug -t
   lib/metrics_probe.dart`, `adb install -t`, and read the lines with
   `adb logcat -d -s flutter:I`.
2. For each state and rotation:
   ```sh
   adb shell cmd device_state state 0|1|2        # CLOSED / HALF_OPENED / OPENED
   adb shell settings put system accelerometer_rotation 0
   adb shell settings put system user_rotation 0|1|3
   adb shell dumpsys SurfaceFlinger --display-id  # physical ids: inner, cover
   adb exec-out screencap -d <physical id> -p > shot.png
   ```
   `screencap -d 0` fails on the two-display AVD; pass the physical id.
3. From the screenshots: the clock's left edge, the status icons' right
   edge (light app bar, dark glyphs; skip the red DEBUG banner) and the
   gesture pill's box, all in px ÷ the density. Rotation 1 turns the inner
   screen's corner camera to the top-left, rotation 3 moves it out of the
   status bar — together they separate the edge insets from the cutout gaps.
4. `cmd device_state state reset` and `user_rotation 0` afterwards.

Findings worth knowing: half-open reports exactly the open metrics with the
fold `postureHalfOpened`; the emulator draws the half-open device flat and
switches postures without animating. The status bar is as tall as a
top-edge cutout reaches (55.79 open, 62.36 closed) and otherwise Android's
default (36 on the inner screen's size class, 52 on the cover's).

## Samsung covers — from the skins

Download the three skins, signed in, from
developer.samsung.com/galaxy-emulator-skin/galaxy-z.html (a Samsung account
is required; the files are not redistributed). Each has a `Main_Screen` and
a `Cover_Screen` skin; the script reads the cover one, zipped or unpacked.

Their open postures are hand-authored and kept as they are. The cover is
built to match:

- **Frame** — the open frame's template and palette (side buttons, rim,
  body, sheen, bezel), at the cover body's size, per-corner radii (from the
  45° diagonal of its silhouette — the skin's art sits on a blue-grey
  backdrop with the model name printed on it, so the body is segmented as
  the neutral grey / near-black region connected to the screen), screen
  position and button positions (the skin layout's `buttons`).
- **Screen** — `fore_port.png`: opaque pixels cover the screen. Its corner
  radii (some masks carry a 1–4 px opaque border, ignored) and every island
  touching no edge — a camera hole, or the Flip8 cover's camera rings and
  flash — punched through the outline and reported as `cutout` features.
- **Safe areas** — the open posture's insets, the status bar grown so a
  top camera hole sits centred in it (the side bar in landscape), and any
  other edge's cutout taking that edge's inset past it.
- **Pixel ratio** — the device's (Samsung uses one density on both
  displays), so the cover declares none.

Check the screen sizes against the spec pages
(samsung.com/<region>/smartphones/galaxy-z-fold8/specs/ …, rendered with
JavaScript — read them in a browser): Fold8 1848 × 2448 / 1248 × 1972,
Fold8 Ultra 2256 × 2504 / 1080 × 2520, Flip8 1080 × 2520 / 948 × 1048.

No emulator image runs One UI, and the fold image only offers fold states
with the Pixel's own overlays, so the Samsung covers are not probed.
