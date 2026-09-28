import 'dart:ui' as ui;

import 'package:device_preview/device_preview.dart';
import 'package:device_preview/presets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_binding.dart';

/// Postures end to end: the controller folds the simulated device and a real
/// widget tree sees exactly what a Flutter app on that device reports.
void main() {
  final TestDevicePreviewBinding binding =
      TestDevicePreviewBinding.ensureInitialized();

  tearDown(() async {
    await binding.devicePreview?.reset();
  });

  late MediaQueryData data;
  Widget probe() => MaterialApp(
    home: Builder(
      builder: (BuildContext context) {
        data = MediaQuery.of(context);
        return const SizedBox.expand();
      },
    ),
  );

  DevicePreviewController controller() => binding.devicePreview!;

  testWidgets('the Duo opens, folds and bends the way the device reports', (
    WidgetTester tester,
  ) async {
    await controller().applyPreset(
      DevicePresets.iPhoneDuo,
      posture: DevicePosture.closed,
    );
    await tester.pumpWidget(probe());
    expect(data.size, const Size(466, 678));
    expect(data.devicePixelRatio, 3);
    expect(data.viewPadding, const EdgeInsets.only(right: 84, bottom: 34));
    expect(data.displayFeatures, isEmpty);
    expect(controller().simulation!.posture, DevicePosture.closed);

    await controller().setPosture(DevicePosture.open);
    await tester.pump();
    expect(data.size, const Size(669, 951));
    expect(data.viewPadding, const EdgeInsets.only(top: 82, bottom: 34));
    expect(data.displayFeatures, isEmpty);
    expect(controller().simulation!.posture, DevicePosture.open);

    // Bending the hinge changes nothing a Flutter app on iOS can observe…
    await controller().setPosture(DevicePosture.halfOpened);
    await tester.pump();
    expect(data.size, const Size(669, 951));
    expect(data.displayFeatures, isEmpty);
    // …but the device knows its fold is now in the way.
    expect(
      controller().simulation!.reservedRegions!
          .singleWhere(
            (SimulatedReservedRegion r) =>
                r.kind == ReservedRegionKind.division,
          )
          .isActive,
      isTrue,
    );
  });

  testWidgets('rotating keeps the posture, folding keeps the orientation', (
    WidgetTester tester,
  ) async {
    await controller().applyPreset(
      DevicePresets.iPhoneDuo,
      posture: DevicePosture.closed,
    );
    await tester.pumpWidget(probe());
    await controller().setOrientation(Orientation.landscape);
    await tester.pump();
    expect(controller().simulation!.posture, DevicePosture.closed);
    expect(data.size, const Size(678, 466));
    expect(data.viewPadding, const EdgeInsets.only(left: 84, bottom: 34));

    await controller().setPosture(DevicePosture.open);
    await tester.pump();
    expect(controller().simulation!.orientation, Orientation.landscape);
    expect(data.size, const Size(951, 669));
    expect(data.viewPadding, const EdgeInsets.only(right: 84, bottom: 34));
    // The status column stays on the right, as iOS lays it out.
    expect(
      controller().simulation!.reservedRegions!.first.bounds,
      const ui.Rect.fromLTRB(867, 0, 951, 120),
    );
  });

  testWidgets('a raised keyboard follows the posture it is in', (
    WidgetTester tester,
  ) async {
    await controller().applyPreset(DevicePresets.iPhoneDuo);
    await controller().update(
      (DeviceSimulation s) => s.copyWith(
        keyboardInset: DevicePresets.iPhoneDuo.keyboardHeight(s.orientation),
      ),
    );
    await tester.pumpWidget(probe());
    expect(data.viewInsets.bottom, 350);

    await controller().setPosture(DevicePosture.halfOpened);
    await tester.pump();
    expect(data.viewInsets.bottom, 495.5);

    await controller().setPosture(DevicePosture.closed);
    await tester.pump();
    expect(data.viewInsets.bottom, 289);
    // The keyboard swallows the home-indicator inset, as on the device.
    expect(data.padding.bottom, 0);
  });

  testWidgets('each posture brings its own frame', (WidgetTester tester) async {
    await controller().applyPreset(DevicePresets.iPhoneDuo);
    final DeviceFrame? inner = controller().simulation!.frame;
    await controller().setPosture(DevicePosture.closed);
    final DeviceFrame? cover = controller().simulation!.frame;
    expect(inner, isNotNull);
    expect(cover, isNotNull);
    expect(cover, isNot(inner));
    // The fitted content grows to include the body the posture shows.
    expect(
      controller().simulation!.contentBounds.width,
      cover!.size.width,
    );
  });

  testWidgets('the overlay switch survives a device switch; postures do '
      'not leak onto devices without them', (WidgetTester tester) async {
    await controller().applyPreset(
      DevicePresets.iPhoneDuo,
      posture: DevicePosture.closed,
    );
    await controller().update(
      (DeviceSimulation s) => s.copyWith(showReservedRegions: true),
    );
    await controller().applyPreset(DevicePresets.iPhone17Pro);
    final DeviceSimulation phone = controller().simulation!;
    expect(phone.showReservedRegions, isTrue);
    expect(phone.posture, isNull);
    expect(phone.reservedRegions, isNull);
    expect(phone.screenSize, const ui.Size(402, 874));

    // setPosture is a no-op on a device that does not fold.
    await controller().setPosture(DevicePosture.closed);
    expect(controller().simulation, phone);
  });

  test('applying an unsupported posture throws before anything changes', () {
    expect(
      () => controller().applyPreset(
        DevicePresets.iPhone17Pro,
        posture: DevicePosture.closed,
      ),
      throwsArgumentError,
    );
  });

  testWidgets('a spec loaded from JSON folds too', (WidgetTester tester) async {
    await controller().applyJson(
      DevicePresets.iPhoneDuo.toJson(),
      posture: DevicePosture.closed,
    );
    await tester.pumpWidget(probe());
    expect(data.size, const Size(466, 678));
    await controller().setPosture(DevicePosture.open);
    await tester.pump();
    expect(data.size, const Size(669, 951));
  });
}
