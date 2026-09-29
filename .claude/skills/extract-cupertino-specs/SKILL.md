---
name: extract-cupertino-specs
description: Rebuild the Apple device specs in device_specs/ from the locally installed iOS Simulator — frame artwork from Xcode's bezel chrome, plus screen size, scale and safe areas probed from a booted simulator (and, for the foldable iPhone Duo, per-posture metrics and reserved regions). Use when iPhone/iPad specs need to be (re)derived from Apple's own definitions.
---

# iOS Simulator → device specs

Rebuilds every Apple spec in `device_specs/` from the simulator that ships
with the locally installed Xcode, using two complementary sources:

1. **Static artwork** — the bezel chrome and framebuffer masks inside Xcode
   rebuild the `frame` object (`size`, `screenOffset`, `screenPath`, `body`):
   the same artwork the Simulator uses for *Window ▸ Show Device Bezels*.
2. **A live probe** — a throwaway simulator per device type is booted and a
   tiny UIKit app reports the metrics iOS actually applies: `portraitSize`,
   `devicePixelRatio`, `portraitPadding` and `landscapePadding` (safe areas
   in both orientations). Safe areas exist in **no static file** — UIKit
   computes them at runtime, so asking a booted simulator is the only
   faithful source.

Hand-authored content the simulator cannot know is preserved: `year`,
`systemUi` artwork, the Dynamic Island pill (see below), and every metric of
donor-based devices.

## 1. Locate the artwork — never hardcode paths

Apple moves this artwork between Xcode versions, and Xcode itself may be
installed under a versioned name (e.g. `/Applications/Xcode-16.2.0.app`).
Always discover, in this order:

```sh
xcode-select -p                      # the active developer dir
ls /Applications | grep -i xcode     # fallback: versioned installs
```

`DEVELOPER_DIR=…` overrides the selection (the script honors it) — useful
when several Xcodes coexist, which they routinely do: **the newest Xcode
defines the newest devices, but only older Xcodes still ship the bezel
chrome** (see below), and the script pulls each piece from wherever it is.

**Xcode 26 changed the layout.** Device profiles no longer live inside the
Xcode bundle at all: `xcodebuild -downloadPlatform iOS` installs them
system-wide into `/Library/Developer/CoreSimulator/Profiles/DeviceTypes/`
(the runtime volume under `/Library/Developer/CoreSimulator/Volumes/` only
carries the OS). `xcrun simctl list devicetypes -j` prints each type's
`bundlePath` — the fastest way to find them on any version. Xcode 26 also
ships **no DeviceKit chrome** (no `*.devicechrome`, and its `Simulator.app`
`Assets.car` holds only icons); keep an Xcode 16.x installed for the bezel
art. Newer profiles may declare chrome classes no Xcode has art for
(`phone13` = iPhone 16e/17e): `CHROME_FALLBACKS` in the script maps them to
the chassis they physically share (`phone4`, the iPhone 14 body). Note
Xcode 26.x needs macOS 15+ — on 14.x its CoreSimulator `SimRenderServer`
segfaults on every boot and wedges `simctl` (delete + kill
`CoreSimulatorService` to recover).

From the developer dir (`$DEV`), the three relevant sources are:

1. **Device type bundles** — one per simulated device:
   `$DEV/Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/DeviceTypes/<name>.simdevicetype/Contents/Resources/`
   (an identical tree exists under `/Library/Developer/CoreSimulator/Profiles/DeviceTypes/`).
   `profile.plist` is the index; the keys that matter:
   - `chromeIdentifier` — e.g. `com.apple.dt.devicekit.chrome.phone11`; the
     last component names the chrome bundle below.
   - `framebufferMask` — UUID of a PDF next to the plist **and** in
     `DeviceKit/FramebufferMasks/`: the exact vector outline of the display
     (multi-cubic "squircle" corners; notch devices carve the notch into the
     top edge). Coordinates are **physical pixels, y-up**.
   - `mainScreenWidth/Height/Scale` — physical resolution; divide by scale
     for logical points. Cross-check against the probe and the spec's
     `portraitSize` before touching anything.
   - `sensorBarImage` — a PDF that is **empty** on modern devices: the
     Dynamic Island / notch content is rendered by iOS itself, so the island
     is *not* in the mask. Keep the island pill our specs already carry.
   `capabilities.plist` also carries `DeviceCornerRadius`, `marketing-name`,
   `modelIdentifier` and the device idiom — useful for sanity checks.

2. **Chrome bundles** — the bezel drawing per device family:
   `$DEV/Platforms/iPhoneOS.platform/Library/Developer/DeviceKit/Chrome/<chrome>.devicechrome/Contents/Resources/`
   - `chrome.json` — layout metadata. Beware: some bundles (tablet2/3) have
     `//` comments and trailing commas; parse leniently. Keys that matter:
     - `images.sizing.leftWidth` … — bezel border thickness in points when
       there is no composite (tablets, phone4).
     - `paths.simpleOutsideBorder.cornerRadius[X|Y]` + `insets` — Apple's own
       outer corner radius for the body silhouette (it shapes the actual
       Simulator window).
   - `PhoneComposite.pdf` (phones) — the whole bezel on one page. Page size =
     body size; the screen is centered, so border = (page − logical screen)/2.
     Drawn as concentric rounded-rect *strokes* centered on the screen rect
     (paint order outer→inner) plus interior fills; the last opaque fill is
     the screen face. Some generations use nested symmetric fills instead,
     with translucent asymmetric fills as button nubs.
   - `iPadTL.pdf` / `Phone TL.pdf` etc. (9-slice corners/edges, used when
     there is no composite) — corner tiles paint at **natural size**, and the
     ring insets read directly off the tile's nested fills (typically shadow
     at 0, gray hairline at 1, dark at 2, near-black from 7).
   - Button PDFs (`inputs` of type `button`, not `onTop`) are anchored to an
     edge of the padded window (`images.devicePadding` around the body) at
     their `offsets`. At rest (`normal`) they tuck under the body, 1 pt
     proud; the Simulator slides them to `rollover` under the pointer. The
     frames draw the rollover state — 6 pt proud on current iPhones, in the
     button artwork's own fill — and grow just enough to show them.

3. **If neither is found** (future Xcode): search broadly —
   `find "$DEV/.." -iname "*bezel*" -o -iname "*chrome*"`, look for
   `Assets.car` in `Simulator.app` (`xcrun assetutil --info Assets.car` to
   inspect; a third-party extractor such as Asset Catalog Tinkerer or
   `acextract` to dump), and for loose `.tiff/.png` in
   `Simulator.app/Contents/Resources` on very old versions.

## 2. Convert artwork to the spec's SVG subset

The embedded renderer (`package:device_preview/svg.dart`) supports **flat
fills only** — no strokes, no gradients, no images. The conversion is
therefore geometric, not a file-format transcode:

- **`screenPath`** — parse the framebuffer-mask PDF *content stream*: on
  phones the outline is a `W*` **clip path** (`get_drawings()` misses it),
  on iPads a plain fill under a `cm` translate — so track the CTM and read
  the operators `m l c v y h re` directly. Divide by the screen scale, flip
  y (`y' = H − y`), emit `M/L/C/Z` rounded to 2 decimals. The resulting
  outline is wound clockwise (in y-down SVG space); if the old spec's
  `screenPath` had extra subpaths (the Dynamic Island pill, wound
  counter-clockwise so `nonZero` punches the hole), re-append them verbatim.
- **`body` SVG** — nested rounded-rect fills replace the stroke stack
  exactly (a stroke of width *w* centered at inset *c* becomes a fill at
  inset *c − w/2*, covered inside by the next ring). Corner radius at inset
  *k* is `simpleOutsideBorder.cornerRadius − k`. Colors come from the PDF
  fill/stroke colors (`#7e7e7e` gray hairline, `#2c2c2c` dark ring, black).
- **`size` / `screenOffset`** — composite page size and centered border for
  phones; `logical + 2 × sizing` and `(sizing, sizing)` for tablets.

Two chassis shapes the geometry model also covers:

- **Home-button phones** (`phone` chrome, iPhone SE): the 9-slice `sizing`
  is asymmetric (28 pt sides, 111 pt forehead and chin), so `border` is an
  `(x, y)` pair; the profile has **no `framebufferMask`** (a plain
  rectangular display) and the outline is the screen rect; and the Home
  button is an `inputs` entry drawn *on top* — a circular stroke in
  `Home BTN.pdf`, placed with its offset as the top-left origin from the
  bottom anchor — converted to a disc of the stroke color covered by a disc
  of the bezel face.
- **One chrome class, several masks** (tablet4): the M2/M3/M4 Airs share a
  mask per size, while the iPad (A16) / (10th gen) carry their own (a different
  display outline) on the very same 820×1180 panel — always read the mask the
  profile names, never assume it from the panel size.

## 3. Probe the live metrics

`probe.swift` (next to this file) is a UIKit app with no Xcode project —
built by the script with:

```sh
SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path) \
  xcrun swiftc -target arm64-apple-ios16.0-simulator probe.swift -o Probe.app/Probe
```

**SDKROOT is load-bearing**: with the default macOS sysroot the linker
stamps a macOS SDK version into `LC_BUILD_VERSION` and UIKit letterboxes
the app into a smaller compatibility size (e.g. an iPhone 16 Pro reports
390×844 instead of 402×874), silently corrupting every metric. The same
letterboxing hits apps without a `UILaunchScreen` Info.plist entry. The
script verifies the probed size against `profile.plist` and aborts on
mismatch.

Per device the script runs `simctl create` (throwaway device, newest iOS
runtime) → `boot` → `bootstatus -b` → `install` → `launch --console-pty`,
reads the app's single `SPECPROBE {json}` line — screen bounds, scale,
`safeAreaInsets` in portrait, then again after a
`requestGeometryUpdate(.landscapeRight)` — and always shuts down and
deletes the device. Expect ~30–60 s per device.

## 4. Devices Xcode doesn't know yet

With Xcode 26.6 every catalog device has a real simulator, so no donors are
in use — but the mechanism stays for the next unreleased generation. Specs
for absent devices reuse a **donor** (marked `donor` in the mapping table
at the top of `extract_specs.py`). Donors contribute **frame artwork
only**; the probe never overwrites a donor-based spec's hand-authored
metrics:

- Same logical panel → use the donor's mask as-is (e.g. 16e ← iPhone 14,
  whose mask carries the same notch — Apple confirmed this by giving the
  real 16e the very same mask UUID).
- Different size → 9-slice retarget the donor path with `retarget`:
  coordinates past the panel midpoint shift by Δw/Δh, corner clusters
  translate rigidly, centered subpaths (island) shift by Δw/2.

Two more geometry cases the script now handles: a mask PDF authored at a
multiple of the framebuffer (the iPhone Air's is 2×) — coordinates are
normalized by the page/framebuffer ratio, never assumed to be pixels; and a
chrome class serving several panel sizes with a composite drawn for only
one of them (phone12 → 16 Pro Max *and* Air, tablet4 → 11" Air only) —
stroke-stack composites lend their ring stack shifted to the panel's own
`sizing` border, nested-fill ones fall back to the 9-slice tiles.

## 5. Run it

```sh
python3 -m venv /tmp/specs-venv && /tmp/specs-venv/bin/pip install pymupdf
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
  /tmp/specs-venv/bin/python .claude/skills/extract-cupertino-specs/extract_specs.py
# --no-probe   frames only, no simulators booted (fast)
# --dry-run    report without writing
# ids...       limit to specific spec ids
```

The script prints every metric it changes and refuses to touch a spec whose
size disagrees with the simulator profile. After it writes:

```sh
cd device_preview_devtools_extension && dart run tool/generate_device_catalog.dart
flutter test                                  # extension suite
cd ../device_preview && flutter test          # package suite
../tool/build_devtools_extension.sh           # committed extension bundle
../tool/build_demo.sh                         # docs demo
```

## 6. iPhone Duo (foldables)

The Duo is not in `extract_specs.py`'s table: it has two displays, postures,
and chrome that assumes nothing the phone pipeline assumes. Two tools cover
it instead.

**Frames — `extract_duo.py`.** `capabilities.plist` lists the displays:
`primary` is the cover (466 × 678 @3, `phone15` chrome), `primary-1` the
inner display (669 × 951 @3, `phone14` chrome). Their chrome bundles live
system-wide in `/Library/Developer/DeviceKit/Chrome/` (installed with the
iOS 27.1 platform — Xcode 27 is the first to ship chrome again). What is
unusual, and why shapes are converted path by path:

- the cover's bezel is asymmetric (left 26 / right 22 in `chrome.json`, a
  separate spine strip along the hinge, nearly square hinge-side corners)
  and its composite puts the screen at x = 25;
- the inner composite surrounds the **physical** 626 × 890 pt panel
  (1878 × 2670 px, 430 ppi) that iOS downsamples 669 × 951 pt onto — the
  artwork is scaled by 669 / 626 onto the logical screen;
- strokes become fills of their outline offset outward by half the stroke
  width (Tiller–Hanson on each cubic), clipped fills become their clip path;
- the half-open frame is the inner one with its bezel pinched into a V at
  the fold (`HALF_OPEN_PINCH`, Device Hub's look at the default angle), the
  screen left rectangular — the app is laid out flat on the device.

The cover camera is not in the mask (iOS draws it, like the Dynamic
Island); it comes from UIKit's own occlusion region for it.

```sh
/tmp/specs-venv/bin/python .claude/skills/extract-cupertino-specs/extract_duo.py
```

**Metrics — `posture_probe.swift`, by hand.** No `simctl` command changes a
posture; Device Hub (Xcode ▸ Open Developer Tool ▸ Device Hub) does, with
its closed / half-open / open buttons and a rotate button. Install the probe
on the booted Duo, launch it with `SIMCTL_CHILD_PASSIVE=1 xcrun simctl
launch --console-pty booted dev.devicepreview.duoprobe`, then set each pose
in Device Hub and read the `DUOPROBE` line it prints. What it found on iOS
27.1, and what `apple-iphone-duo.json` records:

| Pose | Size | Safe area | Keyboard |
|---|---|---|---|
| open, portrait | 669 × 951 | top 82, bottom 34 | 350 |
| open, landscape (either) | 951 × 669 | right 84, bottom 34 | 264 |
| half-open, portrait | 669 × 951 | top 82, bottom 34 | 495.5 (split) |
| closed, portrait | 466 × 678 | right 84, bottom 34 | 289 |
| closed, landscapeRight | 678 × 466 | left 84, bottom 34 | 230 |

Traps: iOS refuses `requestGeometryUpdate` on the inner display (rotate in
Device Hub); the status bar lives in a column on the **trailing** edge on the
cover and on the open display in landscape (both landscapes — it does not
turn with the hardware, so landscape regions are declared, not rotated);
the reserved regions (`occlusion` for the cameras and the status column,
`division` for the fold, 40 pt with 20 pt margins, active only half-open)
lag the hinge by up to a second, so read a pose after it settles; iOS 27
draws **no home indicator** on the Duo, though the 34 pt bottom inset stays.

**Status bar — `duo_status_bar.py`.** The Duo's status bar is iOS 27's:
the clock over (or beside) the wifi glyph inside the battery level ring,
with the cellular bars as four dots under it — in a column along the trailing
edge, or in a row on the open display in portrait. The artwork is Apple's
own: the iOS and iPadOS 27 UI kit (Apple Design Resources, Figma) ▸ page
*Status Bars and Menu Bars* ▸ *Status bar - iPhone Duo*, both variants
exported as SVG. The script keeps the path data verbatim, turns the stroked
ring into a filled arc, and writes the placement fitted against the
simulator (template matching at 3x with the status bar pinned to 9:41 by
`xcrun simctl status_bar booted override`; `clear` afterwards). The fit is
within one physical pixel in every pose.

```sh
python3 .claude/skills/extract-cupertino-specs/duo_status_bar.py \
  ~/Downloads/Type=Horizontal.svg ~/Downloads/Type=Vertical.svg
```

Cross-check against Flutter itself: a stock app on the booted Duo reports the
same sizes, `viewPadding` and keyboard `viewInsets`, and an **empty**
`MediaQuery.displayFeatures` in every pose — Flutter's iOS embedder does not
read reserved regions (flutter/flutter#192515, #193025) — which is why the
spec declares no display feature.

## Licensing note

The artwork inside Xcode is Apple's copyrighted material. So is the UI kit
the Duo's status bar glyphs come from: unlike every other frame here, those
paths are Apple's drawing reproduced verbatim (as the existing iPhone status
bar glyphs are, from their reference drawing), downloaded under the Apple
Design Resources license — check it covers your use before publishing. This process does
not redistribute it: it derives geometry (sizes, radii, paths, insets) and a
handful of flat colors, and the drawn frames are our own minimal SVG. For
marketing-grade imagery use the official Apple Design Resources ("Product
Bezels") instead, which come with clearer usage terms.
