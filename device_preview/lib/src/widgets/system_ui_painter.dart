import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../model/simulation.dart';
import '../model/system_ui.dart';
import '../svg/svg_drawing.dart';

/// Parses a [SystemUiSimulation] once and paints it over the app.
///
/// Each bar fills the safe area on its side of the screen; artwork is drawn at
/// its natural (view box) size, anchored to the leading edge, the center, or
/// the trailing edge. Nothing is stretched, so one description covers every
/// screen width and both orientations.
///
/// Malformed artwork is failure-isolated exactly like device bodies: reported
/// once through [FlutterError.reportError], then skipped.
class SystemUiPainter {
  /// Creates a painter for [systemUi].
  SystemUiPainter(this.systemUi);

  /// The description this painter draws.
  final SystemUiSimulation systemUi;

  final Map<String, SvgDrawing?> _parsed = <String, SvgDrawing?>{};

  /// Paints the bars of a screen of [screenSize] whose safe area is [padding].
  ///
  /// The canvas origin must be the screen's top-left corner. Bars whose safe
  /// area is zero are skipped. [cutouts] are the screen's display cutouts, in
  /// the same coordinates: a bar's leading and trailing artwork moves clear
  /// of any it would overlap (see [SystemUiBar.cutoutGap]).
  void paint(
    ui.Canvas canvas, {
    required ui.Size screenSize,
    required EdgeInsets padding,
    required SystemUiColors colors,
    required TextDirection textDirection,
    List<ui.Rect> cutouts = const <ui.Rect>[],
  }) {
    final SystemUiBar? statusBar = systemUi.statusBar;
    if (statusBar != null && padding.top > 0) {
      _paintBar(
        canvas,
        bar: statusBar,
        region: ui.Rect.fromLTWH(0, 0, screenSize.width, padding.top),
        background: colors.statusBarBackground,
        divider: const ui.Color(0x00000000),
        dividerAtTop: false,
        tint: colors.statusBarIcons,
        textDirection: textDirection,
        cutouts: cutouts,
      );
    }
    final SystemUiBar? navigationBar = systemUi.navigationBar;
    if (navigationBar != null && padding.bottom > 0) {
      _paintBar(
        canvas,
        bar: navigationBar,
        region: ui.Rect.fromLTWH(
          0,
          screenSize.height - padding.bottom,
          screenSize.width,
          padding.bottom,
        ),
        background: colors.navigationBarBackground,
        divider: colors.navigationBarDivider,
        dividerAtTop: true,
        tint: colors.navigationBarIcons,
        textDirection: textDirection,
        cutouts: cutouts,
      );
    }
    final SystemUiBar? sideBar = systemUi.sideBar;
    if (sideBar != null && padding.right > 0) {
      // Clipped to the space between the top and bottom bars, so the
      // column never overlaps the gesture pill.
      _paintSideBar(
        canvas,
        bar: sideBar,
        region: ui.Rect.fromLTRB(
          screenSize.width - padding.right,
          padding.top,
          screenSize.width,
          screenSize.height - padding.bottom,
        ),
        tint: colors.statusBarIcons,
      );
    }
  }

  /// A status bar laid out down a side column: leading at the top, center
  /// in the middle, trailing at the bottom, each centered across the
  /// column. Never mirrored — the column follows the hardware (see
  /// [SystemUiSimulation.sideBar]).
  void _paintSideBar(
    ui.Canvas canvas, {
    required SystemUiBar bar,
    required ui.Rect region,
    required ui.Color tint,
  }) {
    for (final (String source, int alignment) in <(String, int)>[
      (bar.leading, -1),
      (bar.center, 0),
      (bar.trailing, 1),
    ]) {
      if (source.isEmpty) {
        continue;
      }
      final SvgDrawing? drawing = _drawing(source);
      if (drawing == null || drawing.isEmpty || drawing.size.isEmpty) {
        continue;
      }
      final ui.Size size = drawing.size;
      final double top = switch (alignment) {
        < 0 => region.top + bar.inset,
        0 => region.center.dy - size.height / 2,
        _ => region.bottom - bar.inset - size.height,
      };
      final double clampedTop = math.max(
        region.top,
        math.min(top, region.bottom - size.height),
      );
      drawing.paintInto(
        canvas,
        ui.Rect.fromLTWH(
          region.center.dx - size.width / 2,
          clampedTop,
          size.width,
          size.height,
        ),
        currentColor: tint,
      );
    }
  }

  void _paintBar(
    ui.Canvas canvas, {
    required SystemUiBar bar,
    required ui.Rect region,
    required ui.Color background,
    required ui.Color divider,
    required bool dividerAtTop,
    required ui.Color tint,
    required TextDirection textDirection,
    required List<ui.Rect> cutouts,
  }) {
    if (background.a > 0) {
      canvas.drawRect(region, ui.Paint()..color = background);
    }
    if (divider.a > 0) {
      canvas.drawRect(
        ui.Rect.fromLTWH(
          region.left,
          dividerAtTop ? region.top : region.bottom - 1,
          region.width,
          1,
        ),
        ui.Paint()..color = divider,
      );
    }
    final bool rtl = textDirection == TextDirection.rtl;
    // Right-to-left mirrors the whole bar, its insets and gaps included.
    final (double, double) leadingSide = (bar.inset, bar.effectiveCutoutGap);
    final (double, double) trailingSide = (
      bar.effectiveTrailingInset,
      bar.effectiveTrailingCutoutGap,
    );
    // Only the cutouts that reach into this bar move anything.
    final List<ui.Rect> inBar = <ui.Rect>[
      for (final ui.Rect cutout in cutouts)
        if (cutout.top < region.bottom && cutout.bottom > region.top) cutout,
    ];
    _paintArtwork(
      canvas,
      source: rtl ? bar.trailing : bar.leading,
      region: region,
      bar: bar,
      alignment: -1,
      tint: tint,
      side: rtl ? trailingSide : leadingSide,
      cutouts: inBar,
    );
    _paintArtwork(
      canvas,
      source: bar.center,
      region: region,
      bar: bar,
      alignment: 0,
      tint: tint,
    );
    _paintArtwork(
      canvas,
      source: rtl ? bar.leading : bar.trailing,
      region: region,
      bar: bar,
      alignment: 1,
      tint: tint,
      side: rtl ? leadingSide : trailingSide,
      cutouts: inBar,
    );
  }

  /// [alignment] is -1 (the left edge), 0 (centered) or 1 (the right
  /// edge). [side] is the (inset, cutout gap) pair of that edge; artwork
  /// that would overlap one of [cutouts] moves past it toward the center.
  void _paintArtwork(
    ui.Canvas canvas, {
    required String source,
    required ui.Rect region,
    required SystemUiBar bar,
    required int alignment,
    required ui.Color tint,
    (double, double) side = (0, 0),
    List<ui.Rect> cutouts = const <ui.Rect>[],
  }) {
    if (source.isEmpty) {
      return;
    }
    final SvgDrawing? drawing = _drawing(source);
    if (drawing == null || drawing.isEmpty || drawing.size.isEmpty) {
      return;
    }
    final ui.Size size = drawing.size;
    final (double inset, double gap) = side;
    double left = switch (alignment) {
      < 0 => region.left + inset,
      0 => region.center.dx - size.width / 2,
      _ => region.right - inset - size.width,
    };
    if (alignment != 0) {
      // Nearest first, so artwork pushed past one cutout still clears the
      // next.
      final List<ui.Rect> sorted = List<ui.Rect>.of(cutouts)
        ..sort(
          (ui.Rect a, ui.Rect b) => alignment < 0
              ? a.left.compareTo(b.left)
              : b.right.compareTo(a.right),
        );
      for (final ui.Rect cutout in sorted) {
        final bool overlaps =
            left < cutout.right + gap && left + size.width > cutout.left - gap;
        if (!overlaps) {
          continue;
        }
        left = alignment < 0
            ? cutout.right + gap
            : cutout.left - gap - size.width;
      }
    }
    final double? bottomInset = bar.bottomInset;
    final double top = bottomInset == null
        ? region.center.dy - size.height / 2
        : region.bottom - bottomInset - size.height;
    // Never let artwork spill outside its own bar.
    final double clampedTop = math.max(region.top, math.min(top, region.bottom - size.height));
    drawing.paintInto(
      canvas,
      ui.Rect.fromLTWH(left, clampedTop, size.width, size.height),
      currentColor: tint,
    );
  }

  SvgDrawing? _drawing(String source) {
    return _parsed.putIfAbsent(source, () {
      try {
        return SvgDrawing.parse(source);
      } catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'device_preview',
            context: ErrorDescription('while parsing simulated system UI'),
          ),
        );
        return null;
      }
    });
  }
}

/// Paints the band a simulated software keyboard occupies at the bottom of
/// the screen.
///
/// Not a drawing of a keyboard layout: no keys to press, no glyphs to read,
/// nothing that would pretend to be a particular keyboard app. What matters
/// is the space — the app has already laid out around it, because the same
/// height travels as `MediaQuery.viewInsets.bottom` — and a hatched band with
/// a small keyboard mark says what that space is, instead of leaving a
/// mysterious empty strip.
///
/// The band is translucent (80%) and striped: what the keyboard covers stays
/// legible underneath, which is the question being asked in the first place —
/// *what is under there?* — and the diagonal hatch keeps the band reading as
/// an overlay rather than as a surface the app itself painted.
///
/// The mark is drawn here, from primitives, rather than taken from an icon
/// set: the package depends on Flutter alone, and one outline, eight dots and
/// a space bar need no library and no licence.
///
/// The canvas origin must be the screen's top-left corner. [inset] is the
/// keyboard height in the same (simulated logical) pixels as [screenSize];
/// nothing is painted when it is not positive.
void paintSimulatedKeyboard(
  ui.Canvas canvas, {
  required ui.Size screenSize,
  required double inset,
}) {
  if (inset <= 0 || screenSize.isEmpty) {
    return;
  }
  final double height = math.min(inset, screenSize.height);
  final ui.Rect band = ui.Rect.fromLTWH(
    0,
    screenSize.height - height,
    screenSize.width,
    height,
  );
  // Rounded where it meets the app, square where it meets the screen edge:
  // the shape every platform gives a panel that slides up from the bottom.
  final ui.RRect shape = ui.RRect.fromRectAndCorners(
    band,
    topLeft: const ui.Radius.circular(kKeyboardBandRadius),
    topRight: const ui.Radius.circular(kKeyboardBandRadius),
  );
  // One near-black grey in both brightnesses, at 80%: the band stands for a
  // surface covering the app, and the app has to stay readable through it.
  canvas
    ..drawRRect(shape, ui.Paint()..color = const ui.Color(0xCC17171A))
    ..save()
    // Everything else stays inside the rounded shape, so the hatching and the
    // hairline follow the corners instead of cutting across them.
    ..clipRRect(shape);
  _paintHatch(canvas, band);
  // A hairline where the keyboard meets the app, the way both platforms
  // separate it from the content behind.
  canvas
    ..drawRect(
      ui.Rect.fromLTWH(band.left, band.top, band.width, 1),
      ui.Paint()..color = const ui.Color(0x1FFFFFFF),
    )
    ..restore();

  // The mark, centered and deliberately quiet — it labels the band, it is not
  // decoration to look at. Sized off the band so it stays proportionate from
  // a landscape phone strip to an iPad's half-screen keyboard.
  final double size = math.min(
    math.min(band.height * 0.30, band.width * 0.20),
    56,
  );
  if (size < 16) {
    return;
  }
  canvas
    ..save()
    ..translate(band.center.dx - size / 2, band.center.dy - size / 2)
    ..scale(size / 16);
  _paintKeyboardMark(canvas);
  canvas.restore();
}

/// The radius of the band's top corners, in simulated logical pixels.
const double kKeyboardBandRadius = 8;

/// Fills [band] with 45° hatching, clipped to it.
///
/// Every stripe runs bottom-left to top-right at a fixed pitch in simulated
/// logical pixels, so the texture reads the same on a phone and on a tablet
/// and does not shimmer when the device changes.
void _paintHatch(ui.Canvas canvas, ui.Rect band) {
  const double pitch = 12;
  final ui.Paint stripe = ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1
    ..color = const ui.Color(0x14FFFFFF);
  canvas
    ..save()
    ..clipRect(band);
  // Start a full band-height to the left so the first slanted stripe still
  // crosses the band's left edge.
  // (The caller has already clipped to the rounded shape.)
  for (
    double x = band.left - band.height;
    x < band.right;
    x += pitch
  ) {
    canvas.drawLine(
      ui.Offset(x, band.bottom),
      ui.Offset(x + band.height, band.top),
      stripe,
    );
  }
  canvas.restore();
}

/// Draws the keyboard mark on a 16×16 grid at the canvas origin: a rounded
/// outline, two rows of keys and a space bar.
///
/// Geometric monoline on the 16-unit grid, the neutral drawing style of
/// Vercel's Geist icons: one hairline weight throughout, small corner radii,
/// round caps, keys as dots of exactly the stroke's own width.
void _paintKeyboardMark(ui.Canvas canvas) {
  const ui.Color ink = ui.Color(0x40FFFFFF);
  const double weight = 1.0;
  final ui.Paint stroke = ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = weight
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round
    ..color = ink;
  final ui.Paint fill = ui.Paint()..color = ink;

  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(
      const ui.Rect.fromLTRB(1.25, 3.75, 14.75, 12.25),
      const ui.Radius.circular(1.75),
    ),
    stroke,
  );
  for (final double y in <double>[6.3, 8.6]) {
    for (final double x in <double>[4.0, 6.5, 9.0, 11.5]) {
      canvas.drawCircle(ui.Offset(x, y), 0.55, fill);
    }
  }
  // The space bar: the one element that makes the outline read as a keyboard
  // rather than as a window.
  canvas.drawLine(
    const ui.Offset(5.5, 10.6),
    const ui.Offset(10.5, 10.6),
    stroke,
  );
}

/// Paints [regions] — a simulated device's reserved regions — as a
/// translucent overlay: what `DeviceSimulation.showReservedRegions` turns on.
///
/// Occlusions are red, divisions blue, matching the "keep out" and "split
/// here" readings of the two kinds:
///
/// * an **active** region is filled — its core strongly, its margins (the
///   breathing room around a fold) faintly — and a division's crease is
///   drawn as a line, since a fold's core is often zero wide;
/// * an **inactive** region, one the device reports but does not currently
///   apply (the inner camera while it is off, the fold while the device lies
///   flat), is only outlined, so a layout can be checked against where it
///   *will* be.
///
/// The canvas origin must be the screen's top-left corner; [regions] are in
/// the same (simulated logical) pixels.
void paintReservedRegions(
  ui.Canvas canvas,
  List<SimulatedReservedRegion> regions,
) {
  for (final SimulatedReservedRegion region in regions) {
    final bool division = region.kind == ReservedRegionKind.division;
    final ui.Color hue = division
        ? const ui.Color(0xFF0A84FF)
        : const ui.Color(0xFFFF453A);
    final ui.Rect core = region.core;
    if (region.isActive) {
      canvas.drawRect(
        region.bounds,
        ui.Paint()..color = hue.withValues(alpha: 0.14),
      );
      if (!core.isEmpty) {
        canvas.drawRect(core, ui.Paint()..color = hue.withValues(alpha: 0.30));
      }
      if (division) {
        final ui.Paint line = ui.Paint()
          ..color = hue.withValues(alpha: 0.9)
          ..strokeWidth = 1.5;
        final ui.Offset center = core.center;
        if (core.width <= core.height) {
          canvas.drawLine(
            ui.Offset(center.dx, core.top),
            ui.Offset(center.dx, core.bottom),
            line,
          );
        } else {
          canvas.drawLine(
            ui.Offset(core.left, center.dy),
            ui.Offset(core.right, center.dy),
            line,
          );
        }
      }
    }
    canvas.drawRect(
      region.bounds.deflate(0.5),
      ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = hue.withValues(alpha: region.isActive ? 0.9 : 0.55),
    );
  }
}

/// The creases of a partially open foldable: the lines along which its
/// screen is currently bent — a fold or hinge display feature in
/// `postureHalfOpened` (Android). Empty for a device lying flat, and for
/// the iPhone Duo: its hinge is a reserved-region division, which Xcode's
/// Device Hub draws without any crease on the screen.
///
/// Each crease is the center line of its feature, along the feature's
/// longer side.
List<(ui.Offset, ui.Offset)> foldCreases({
  List<SimulatedReservedRegion>? regions,
  List<SimulatedDisplayFeature>? features,
}) {
  (ui.Offset, ui.Offset) centerLine(ui.Rect rect) {
    final ui.Offset c = rect.center;
    return rect.width <= rect.height
        ? (ui.Offset(c.dx, rect.top), ui.Offset(c.dx, rect.bottom))
        : (ui.Offset(rect.left, c.dy), ui.Offset(rect.right, c.dy));
  }

  // Reserved-region divisions (the iPhone Duo's hinge) draw no crease:
  // Xcode's Device Hub shows the half-open Duo as one continuous screen,
  // bent only in the body around it. `regions` stays in the signature so
  // callers pass what they have; only Android's half-opened folds shade.
  return <(ui.Offset, ui.Offset)>[
    for (final SimulatedDisplayFeature feature
        in features ?? const <SimulatedDisplayFeature>[])
      if ((feature.type == ui.DisplayFeatureType.fold ||
              feature.type == ui.DisplayFeatureType.hinge) &&
          feature.state == ui.DisplayFeatureState.postureHalfOpened)
        centerLine(feature.bounds),
  ];
}

/// Shades each crease of a bent screen — [foldCreases] — the way light
/// falls off across a fold: darkest on the crease, fading out over
/// [halfWidth] on either side.
///
/// Decoration only, like the bent body the half-open frame draws around the
/// screen: the app stays laid out flat and unshaded underneath, exactly as
/// the device lays it out. The canvas origin must be the screen's top-left
/// corner.
void paintFoldCreases(
  ui.Canvas canvas,
  List<(ui.Offset, ui.Offset)> creases, {
  double halfWidth = 36,
}) {
  for (final (ui.Offset from, ui.Offset to) in creases) {
    final bool vertical = (to.dx - from.dx).abs() < (to.dy - from.dy).abs();
    final ui.Rect band = vertical
        ? ui.Rect.fromLTRB(
            from.dx - halfWidth,
            from.dy,
            from.dx + halfWidth,
            to.dy,
          )
        : ui.Rect.fromLTRB(
            from.dx,
            from.dy - halfWidth,
            to.dx,
            from.dy + halfWidth,
          );
    final ui.Offset start = vertical ? band.centerLeft : band.topCenter;
    final ui.Offset end = vertical ? band.centerRight : band.bottomCenter;
    canvas.drawRect(
      band,
      ui.Paint()
        ..shader = ui.Gradient.linear(
          start,
          end,
          const <ui.Color>[
            ui.Color(0x00000000),
            ui.Color(0x38000000),
            ui.Color(0x00000000),
          ],
          const <double>[0, 0.5, 1],
        ),
    );
    canvas.drawLine(
      from,
      to,
      ui.Paint()
        ..color = const ui.Color(0x33000000)
        ..strokeWidth = 1,
    );
  }
}
