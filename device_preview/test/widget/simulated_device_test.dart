import 'dart:ui' as ui;

import 'package:device_preview/device_preview.dart';
import 'package:device_preview/presets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('the status bar follows the style the content annotates', (
    WidgetTester tester,
  ) async {
    final DeviceSimulation phone = DevicePresets.iPhone16Pro.resolve();
    SystemUiOverlayStyle? style() => tester
        .widget<DevicePreviewFrame>(find.byType(DevicePreviewFrame))
        .overlayStyle!
        .value;
    // No annotation: the bars follow the simulated brightness.
    await pump(
      tester,
      SimulatedDevice(simulation: phone, child: const SizedBox.expand()),
    );
    await tester.pump();
    expect(style(), isNull);
    // An app bar-like region under the status bar styles it; one at the
    // bottom edge styles the navigation bar.
    await pump(
      tester,
      SimulatedDevice(
        simulation: phone,
        child: const Column(
          children: <Widget>[
            AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle.light,
              child: SizedBox(height: 120, width: double.infinity),
            ),
            Spacer(),
            AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                systemNavigationBarIconBrightness: Brightness.dark,
              ),
              child: SizedBox(height: 40, width: double.infinity),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(style()!.statusBarBrightness, Brightness.dark);
    expect(style()!.statusBarIconBrightness, Brightness.light);
    expect(style()!.systemNavigationBarIconBrightness, Brightness.dark);
    // A style passed in wins over the content's.
    await pump(
      tester,
      SimulatedDevice(
        simulation: phone,
        overlayStyle: SystemUiOverlayStyle.dark,
        child: const AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    expect(style(), SystemUiOverlayStyle.dark);
  });

  testWidgets('a foreground lies on the screen, above the system UI', (
    WidgetTester tester,
  ) async {
    final DeviceSimulation phone = DevicePresets.iPhone16Pro.resolve();
    await pump(
      tester,
      SimulatedDevice(
        simulation: phone,
        foreground: const SizedBox.expand(key: ValueKey<String>('fg')),
        child: const SizedBox.expand(key: ValueKey<String>('app')),
      ),
    );
    final Rect app = tester.getRect(find.byKey(const ValueKey<String>('app')));
    expect(tester.getRect(find.byKey(const ValueKey<String>('fg'))), app);
    // Painted after the frame — and so after the system UI it draws.
    final List<Element> order = <Element>[];
    void walk(Element e) {
      order.add(e);
      e.visitChildren(walk);
    }

    tester.binding.rootElement!.visitChildren(walk);
    final int frame = order.indexWhere((e) => e.widget is DevicePreviewFrame);
    final int fg = order.indexWhere(
      (e) => e.widget.key == const ValueKey<String>('fg'),
    );
    expect(fg, greaterThan(frame));
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
