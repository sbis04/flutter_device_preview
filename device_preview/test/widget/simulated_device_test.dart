import 'dart:ui' as ui;

import 'package:device_preview/device_preview.dart';
import 'package:device_preview/presets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// SimulatedDevice: a device as a plain widget, with no binding involved —
/// how a design tool's canvas embeds a device.
void main() {
  late MediaQueryData data;
  Widget screen() => Builder(
    builder: (BuildContext context) {
      data = MediaQuery.of(context);
      return const SizedBox.expand();
    },
  );

  Future<void> pump(WidgetTester tester, Widget device) async {
    tester.view.physicalSize = const Size(3000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: device),
      ),
    );
  }

  testWidgets('sizes to the body and lays the child out on the screen', (
    WidgetTester tester,
  ) async {
    final DeviceSimulation duo = DevicePresets.iPhoneDuo.resolve(
      posture: DevicePosture.closed,
    );
    await pump(tester, SimulatedDevice(simulation: duo, child: screen()));
    final DeviceFrame frame = duo.frame!;
    expect(tester.getSize(find.byType(SimulatedDevice)), frame.size);
    // The child is the screen, at the body's screen offset.
    final Rect child = tester.getRect(find.byType(DevicePreviewFrame));
    expect(child.size, const Size(466, 678));
    expect(
      child.topLeft - tester.getTopLeft(find.byType(SimulatedDevice)),
      frame.screenOffset,
    );
    expect(data.size, const Size(466, 678));
    expect(data.devicePixelRatio, 3);
    expect(data.viewPadding, const EdgeInsets.only(right: 84, bottom: 34));
    expect(data.displayFeatures, isEmpty);
  });

  testWidgets('landscape rotates the body around the screen', (
    WidgetTester tester,
  ) async {
    final DeviceSimulation s = DevicePresets.iPhone17Pro.resolve(
      orientation: Orientation.landscape,
    );
    await pump(tester, SimulatedDevice(simulation: s, child: screen()));
    final Size body = s.frame!.size;
    expect(
      tester.getSize(find.byType(SimulatedDevice)),
      Size(body.height, body.width),
    );
    expect(data.size, const Size(874, 402));
    expect(SimulatedDevice.screenRectOf(s).size, const Size(874, 402));
  });

  testWidgets('without the frame it is exactly the screen', (
    WidgetTester tester,
  ) async {
    final DeviceSimulation s = DevicePresets.iPhone17Pro.resolve();
    await pump(
      tester,
      SimulatedDevice(simulation: s, showFrame: false, child: screen()),
    );
    expect(tester.getSize(find.byType(SimulatedDevice)), const Size(402, 874));
    expect(
      SimulatedDevice.screenRectOf(s, showFrame: false).topLeft,
      Offset.zero,
    );
  });

  testWidgets('a keyboard, a fold and overrides reach the child', (
    WidgetTester tester,
  ) async {
    final DeviceSimulation fold = DevicePresets.galaxyZFold8
        .resolve(posture: DevicePosture.open)
        .copyWith(
          keyboardInset: 336,
          platformBrightness: ui.Brightness.dark,
          textScaleFactor: 1.5,
        );
    await pump(tester, SimulatedDevice(simulation: fold, child: screen()));
    expect(data.viewInsets.bottom, 336);
    expect(data.padding.bottom, 0);
    expect(data.viewPadding.bottom, 24);
    // The fold, besides the inner camera's cutout.
    expect(
      data.displayFeatures.map((f) => f.type),
      containsAll(<ui.DisplayFeatureType>[
        ui.DisplayFeatureType.fold,
        ui.DisplayFeatureType.cutout,
      ]),
    );
    expect(data.platformBrightness, ui.Brightness.dark);
    expect(data.textScaler.scale(10), 15);
  });

  testWidgets('fits smaller constraints and scales to an imposed size', (
    WidgetTester tester,
  ) async {
    final DeviceSimulation s = DevicePresets.iPhone17Pro.resolve();
    final Size natural = SimulatedDevice.sizeOf(s);
    await pump(
      tester,
      SizedBox.fromSize(
        size: natural * 0.5,
        child: SimulatedDevice(simulation: s, child: screen()),
      ),
    );
    // Laid out at the device's size, painted at half of it.
    expect(data.size, const Size(402, 874));
    final Rect painted = tester.getRect(find.byType(DevicePreviewFrame));
    expect(painted.width, closeTo(201, 0.01));
    expect(painted.height, closeTo(437, 0.01));
  });

  testWidgets('follows a new simulation', (WidgetTester tester) async {
    await pump(
      tester,
      SimulatedDevice(
        simulation: DevicePresets.iPhoneDuo.resolve(),
        child: screen(),
      ),
    );
    expect(data.size, const Size(669, 951));
    await pump(
      tester,
      SimulatedDevice(
        simulation: DevicePresets.iPhoneDuo.resolve(
          posture: DevicePosture.closed,
        ),
        child: screen(),
      ),
    );
    expect(data.size, const Size(466, 678));
  });
}
