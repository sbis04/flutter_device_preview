import 'dart:ui' as ui;

import 'package:device_preview/device_preview.dart';
import 'package:device_preview/presets.dart';
import 'package:flutter/widgets.dart' show Orientation, TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DeviceFrame.desktopWindow draws the catalog desktop window', () {
    // The generated frame reproduces the spec'd desktop windows exactly, so
    // an arbitrary size looks like the catalog's own.
    for (final (DevicePreset preset, TargetPlatform platform)
        in <(DevicePreset, TargetPlatform)>[
          (DevicePresets.largeDesktopWindow, TargetPlatform.macOS),
          (DevicePresets.smallDesktopWindow, TargetPlatform.windows),
        ]) {
      final DeviceFrame generated = DeviceFrame.desktopWindow(
        preset.portraitSize,
        platform: platform,
      );
      final DeviceFrame spec = preset.frame!;
      expect(generated.size, spec.size, reason: preset.id);
      expect(generated.screenOffset, spec.screenOffset, reason: preset.id);
      expect(generated.screenPath, spec.screenPath, reason: preset.id);
      expect(generated.body, spec.body, reason: preset.id);
    }
  });

  test('DeviceFrame.desktopWindow parses and encloses any screen', () {
    const ui.Size screen = ui.Size(1512, 982);
    final DeviceFrame frame = DeviceFrame.desktopWindow(screen);
    final DeviceFramePainter painter = DeviceFramePainter(frame);
    expect(painter.body, isNotNull);
    expect(painter.screenPath!.getBounds(), const ui.Rect.fromLTWH(0, 0, 1512, 982));
    expect(
      frame.bodyBounds(screen, Orientation.portrait),
      const ui.Rect.fromLTWH(-1, -28, 1514, 1011),
    );
  });
}
