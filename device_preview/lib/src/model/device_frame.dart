import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'json_utils.dart';

/// The physical appearance of a simulated device: the shape its screen is cut
/// to, and the artwork of the body drawn behind that screen.
///
/// Everything is expressed in **portrait** logical pixels, in the coordinate
/// space of the simulated screen: the screen's top-left corner is the origin,
/// so the body starts at `-screenOffset`. Landscape is not a separate
/// description — the whole frame is rotated at paint time, exactly like
/// turning the real device around.
///
/// ```
///        ┌───────────────────┐  ← body, at (-screenOffset)
///        │  ┌─────────────┐  │
///        │  │   screen    │  │  ← origin (0, 0) at the screen's top-left
///        │  │             │  │
///        │  └─────────────┘  │
///        └───────────────────┘
/// ```
///
/// Both artwork fields are optional: a frame with only a [screenPath] rounds
/// the app's corners with no body, and a frame with only a [body] draws the
/// device around an unclipped rectangular screen.
@immutable
class DeviceFrame {
  /// Creates a device frame description.
  const DeviceFrame({
    required this.size,
    this.screenOffset = ui.Offset.zero,
    this.screenPath = '',
    this.body = '',
    this.landscapeClockwise = false,
  });

  /// Decodes a frame from the JSON produced by [toJson].
  ///
  /// [body] also accepts an array of strings, joined with newlines, so that
  /// device spec files can keep their artwork readable.
  factory DeviceFrame.fromJson(Map<String, Object?> json) {
    return DeviceFrame(
      size: decodeSize(json['size'], 'size'),
      screenOffset: json['screenOffset'] == null
          ? ui.Offset.zero
          : decodeOffset(json['screenOffset'], 'screenOffset'),
      screenPath: json['screenPath'] == null
          ? ''
          : decodeString(json['screenPath'], 'screenPath'),
      body: json['body'] == null
          ? ''
          : decodeStringOrLines(json['body'], 'body'),
      landscapeClockwise: json['landscapeClockwise'] == null
          ? false
          : decodeBool(json['landscapeClockwise'], 'landscapeClockwise'),
    );
  }

  /// The size of the body artwork, in portrait logical pixels.
  final ui.Size size;

  /// The offset of the screen's top-left corner inside the body.
  final ui.Offset screenOffset;

  /// SVG path data for the screen outline, in screen coordinates (the origin
  /// is the screen's top-left corner, portrait).
  ///
  /// Empty for a plain rectangular screen.
  final String screenPath;

  /// The body artwork: an SVG document whose view box covers [size].
  ///
  /// Drawn behind the app, so anything overlapping the screen area is hidden.
  /// Empty when the frame only rounds the screen corners.
  final String body;

  /// Whether the frame turns clockwise into landscape — portrait `(x, y)` to
  /// `(portraitHeight − y, x)` — rather than counter-clockwise, as
  /// [bodyBounds] documents. Only the artwork turns the other way (its side
  /// buttons end up on the opposite edges); the screen's metrics and display
  /// features keep the preset's own landscape. The iPhone Duo's inner frame
  /// sets it: Device Hub shows the open device turned that way.
  final bool landscapeClockwise;

  /// Whether this frame carries no artwork at all.
  bool get isEmpty => screenPath.isEmpty && body.isEmpty;

  /// The body rectangle in screen coordinates, for [orientation] of a screen
  /// of [screenSize] (already orientation-resolved).
  ///
  /// In landscape the frame is rotated a quarter turn, mapping a portrait
  /// point `(x, y)` to `(y, portraitWidth − x)` — the same rotation
  /// `SimulatedDisplayFeature.rotatedToLandscape` applies, so frame and
  /// display features stay physically consistent.
  ui.Rect bodyBounds(ui.Size screenSize, Orientation orientation) {
    final ui.Rect portrait = ui.Rect.fromLTWH(
      -screenOffset.dx,
      -screenOffset.dy,
      size.width,
      size.height,
    );
    if (orientation == Orientation.portrait) {
      return portrait;
    }
    // In landscape the screen is (portraitHeight, portraitWidth).
    final double portraitWidth = screenSize.height;
    if (landscapeClockwise) {
      final double portraitHeight = screenSize.width;
      return ui.Rect.fromLTRB(
        portraitHeight - portrait.bottom,
        portrait.left,
        portraitHeight - portrait.top,
        portrait.right,
      );
    }
    return ui.Rect.fromLTRB(
      portrait.top,
      portraitWidth - portrait.right,
      portrait.bottom,
      portraitWidth - portrait.left,
    );
  }

  /// A desktop window around a screen of [screenSize] — the same artwork as
  /// the catalog's desktop windows (`device_specs/desktop-*.json`), in the
  /// style of [platform]'s windows:
  ///
  /// * macOS (the default, `desktop-large`): a 28 pt title bar with the three
  ///   window controls on the left, 12 pt corners;
  /// * Windows (`desktop-small`): a 32 pt title bar with minimize, maximize
  ///   and close on the right, 8 pt corners;
  ///
  /// both with a title pill centered in the bar. For windows of arbitrary
  /// size — a design tool's desktop breakpoints, a custom canvas — that no
  /// spec describes.
  factory DeviceFrame.desktopWindow(
    ui.Size screenSize, {
    TargetPlatform platform = TargetPlatform.macOS,
  }) {
    String n(double v) {
      final double r = (v * 100).roundToDouble() / 100;
      return r == r.roundToDouble() ? '${r.toInt()}' : '$r';
    }

    final bool mac =
        platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
    final double bar = mac ? 28 : 32;
    final double r = mac ? 12 : 8;
    final String fill = mac ? '#26282c' : '#202226';
    final double w = screenSize.width;
    final double h = screenSize.height;
    final double bw = w + 2;
    final double bh = h + bar + 1;
    final double c = bar / 2;
    return DeviceFrame(
      size: ui.Size(bw, bh),
      screenOffset: ui.Offset(1, bar),
      screenPath:
          'M 0,0 H ${n(w)} V ${n(h - r)} A ${n(r)},${n(r)} 0 0 1 '
          '${n(w - r)},${n(h)} H ${n(r)} A ${n(r)},${n(r)} 0 0 1 0,${n(h - r)} Z',
      body: <String>[
        '<svg viewBox="0 0 ${n(bw)} ${n(bh)}">',
        '  <path d="M ${n(r)},0 H ${n(bw - r)} A ${n(r)},${n(r)} 0 0 1 '
            '${n(bw)},${n(r)} V ${n(bh - r)} A ${n(r)},${n(r)} 0 0 1 '
            '${n(bw - r)},${n(bh)} H ${n(r)} A ${n(r)},${n(r)} 0 0 1 '
            '0,${n(bh - r)} V ${n(r)} A ${n(r)},${n(r)} 0 0 1 ${n(r)},0 Z" '
            'fill="$fill"/>',
        if (mac) ...<String>[
          '  <circle cx="16" cy="${n(c)}" r="6" fill="#ff5f57"/>',
          '  <circle cx="36" cy="${n(c)}" r="6" fill="#febc2e"/>',
          '  <circle cx="56" cy="${n(c)}" r="6" fill="#28c840"/>',
        ] else
          for (final double x in <double>[bw - 46, bw - 32, bw - 18])
            '  <rect x="${n(x)}" y="${n(c - 1)}" width="10" height="2" '
                'fill="#c9ccd1"/>',
        '  <rect x="${n(bw / 2 - 70)}" y="${n(c - 5)}" width="140" height="10" '
            'rx="5" fill="#c9ccd1" fill-opacity="0.35"/>',
        '</svg>',
      ].join('\n'),
    );
  }

  /// This frame without its body artwork: the same screen outline and
  /// placement, so the screen still clips, but nothing drawn around it.
  DeviceFrame copyWithoutBody() => DeviceFrame(
    size: size,
    screenOffset: screenOffset,
    screenPath: screenPath,
    landscapeClockwise: landscapeClockwise,
  );

  /// Encodes this frame as JSON. Empty artwork fields are absent.
  Map<String, Object?> toJson() => <String, Object?>{
    'size': encodeSize(size),
    if (screenOffset != ui.Offset.zero)
      'screenOffset': encodeOffset(screenOffset),
    if (screenPath.isNotEmpty) 'screenPath': screenPath,
    if (body.isNotEmpty) 'body': body,
    if (landscapeClockwise) 'landscapeClockwise': true,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is DeviceFrame &&
        other.size == size &&
        other.screenOffset == screenOffset &&
        other.screenPath == screenPath &&
        other.body == body &&
        other.landscapeClockwise == landscapeClockwise;
  }

  @override
  int get hashCode =>
      Object.hash(size, screenOffset, screenPath, body, landscapeClockwise);

  @override
  String toString() =>
      'DeviceFrame(size: $size, screenOffset: $screenOffset, '
      'screenPath: ${screenPath.length} chars, body: ${body.length} chars)';
}
