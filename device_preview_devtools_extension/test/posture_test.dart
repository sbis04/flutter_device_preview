import 'package:device_preview/device_preview.dart';
import 'package:device_preview/presets.dart';
import 'package:device_preview_devtools_extension/src/devices/device_catalog.g.dart';
import 'package:device_preview_devtools_extension/src/panel_controller.dart';
import 'package:device_preview_devtools_extension/src/platform/platform_io.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_gateway.dart';

/// Foldable postures and reserved regions in the panel — and, above all,
/// parity: the panel and the app are the two writers of the simulation
/// protocol, so for every catalog device, posture and orientation the panel
/// must push exactly the simulation `DevicePreset.resolve` builds app-side.
void main() {
  late FakeGateway gateway;
  late PanelController controller;
  bool started = false;

  Future<void> ready() async {
    gateway = FakeGateway(connected: true, available: true);
    controller = PanelController(
      gateway: gateway,
      storage: InMemoryStorage(),
      saveScreenshot: (_, __) {},
      readyEventTimeout: const Duration(milliseconds: 20),
      bannerDelay: const Duration(milliseconds: 5),
    );
    started = true;
    await pumpEventQueue();
    expect(controller.status, PanelStatus.ready);
  }

  tearDown(() {
    if (!started) return;
    started = false;
    controller.dispose();
    gateway.dispose();
  });

  // Insets a writer may leave out because they are zero: the app reads an
  // absent padding or gesture inset as none while simulating metrics.
  DeviceSimulation normalized(DeviceSimulation s) => s.copyWith(
    padding: s.padding ?? EdgeInsets.zero,
    viewPadding: s.viewPadding ?? s.padding ?? EdgeInsets.zero,
    systemGestureInsets: s.systemGestureInsets ?? EdgeInsets.zero,
  );

  PresetView duoView() =>
      kBuiltInPresets.singleWhere((p) => p.id == 'apple-iphone-duo');

  group('parity with DevicePreset.resolve', () {
    for (final Map<String, Object?> spec in kDeviceSpecs) {
      final DevicePreset preset = DevicePreset.fromJson(spec);
      final List<DevicePosture> postures = preset.hasPostures
          ? preset.supportedPostures
          : const <DevicePosture>[DevicePosture.open];
      for (final DevicePosture posture in postures) {
        test('${preset.id} ${posture.name}', () async {
          await ready();
          final PresetView view = kBuiltInPresets.singleWhere(
            (p) => p.id == preset.id,
          );
          await controller.selectPreset(view);
          if (posture != DevicePosture.open) {
            await controller.setPosture(posture.name);
          }
          for (final Orientation orientation in <Orientation>[
            Orientation.portrait,
            Orientation.landscape,
            Orientation.portrait,
          ]) {
            await controller.setOrientation(orientation.name);
            final DeviceSimulation pushed = DeviceSimulation.fromJson(
              gateway.simulation!,
            );
            final DeviceSimulation expected = preset.resolve(
              orientation: orientation,
              posture: posture,
            );
            expect(
              normalized(pushed),
              normalized(expected),
              reason: '${preset.id} ${posture.name} ${orientation.name}',
            );
          }
        });
      }
    }
  });

  group('PresetView.forPosture', () {
    test('mirrors DevicePreset.forPosture field for field', () {
      for (final Map<String, Object?> spec in kDeviceSpecs) {
        final DevicePreset preset = DevicePreset.fromJson(spec);
        for (final DevicePosture posture in preset.supportedPostures) {
          final PresetView view = PresetView(spec).forPosture(posture.name);
          expect(
            DevicePreset.fromJson(view.json),
            preset.forPosture(posture),
            reason: '${preset.id} ${posture.name}',
          );
        }
      }
    });

    test('lists the postures in the order the panel offers them', () {
      expect(duoView().supportedPostures, <String>[
        'open',
        'halfOpened',
        'closed',
      ]);
      expect(
        kBuiltInPresets
            .singleWhere((p) => p.id == 'apple-iphone-17-pro')
            .supportedPostures,
        isEmpty,
      );
    });
  });

  group('posture control', () {
    test('offers the postures of a foldable only', () async {
      await ready();
      expect(controller.supportedPostures, isEmpty);
      await controller.selectPreset(duoView());
      expect(controller.posture, 'open');
      expect(controller.supportedPostures, <String>[
        'open',
        'halfOpened',
        'closed',
      ]);
      await controller.selectPreset(
        kBuiltInPresets.singleWhere((p) => p.id == 'apple-iphone-17-pro'),
      );
      expect(controller.posture, isNull);
      expect(controller.supportedPostures, isEmpty);
      expect(gateway.simulation!.containsKey('posture'), isFalse);
      expect(gateway.simulation!.containsKey('reservedRegions'), isFalse);
    });

    test('is hidden from an app that cannot round-trip a posture', () async {
      await ready();
      gateway.canPosture = false;
      await controller.selectPreset(duoView());
      expect(controller.supportedPostures, isEmpty);
    });

    test('folding keeps the orientation and moves a raised keyboard to the '
        'new posture height', () async {
      await ready();
      await controller.selectPreset(duoView());
      await controller.setKeyboardVisible(true);
      expect(gateway.simulation!['keyboardInset'], 350);
      await controller.setPosture('halfOpened');
      expect(gateway.simulation!['keyboardInset'], 495.5);
      await controller.setOrientation('landscape');
      expect(controller.posture, 'halfOpened');
      expect(gateway.simulation!['keyboardInset'], 264);
      await controller.setPosture('closed');
      expect(gateway.simulation!['orientation'], 'landscape');
      expect(gateway.simulation!['screenSize'], <String, Object?>{
        'width': 678,
        'height': 466,
      });
      expect(gateway.simulation!['keyboardInset'], 230);
    });

    test('switching between devices keeps a posture the new one has', () async {
      await ready();
      await controller.selectPreset(duoView());
      await controller.setPosture('closed');
      await controller.selectPreset(duoView());
      expect(controller.posture, 'closed');
    });

    test('ignores a posture the device does not have', () async {
      await ready();
      await controller.selectPreset(
        kBuiltInPresets.singleWhere((p) => p.id == 'apple-iphone-17-pro'),
      );
      gateway.calls.clear();
      await controller.setPosture('closed');
      expect(gateway.callsTo('ext.device_preview.setSimulation'), isEmpty);
    });
  });

  group('reserved regions', () {
    test('the overlay switch is offered with regions and survives a device '
        'switch', () async {
      await ready();
      await controller.selectPreset(
        kBuiltInPresets.singleWhere((p) => p.id == 'apple-iphone-17-pro'),
      );
      expect(controller.hasReservedRegions, isFalse);
      await controller.selectPreset(duoView());
      expect(controller.hasReservedRegions, isTrue);
      expect(controller.showReservedRegions, isFalse);
      await controller.setShowReservedRegions(true);
      expect(gateway.simulation!['showReservedRegions'], true);
      await controller.setPosture('closed');
      expect(controller.showReservedRegions, isTrue);
      await controller.setShowReservedRegions(false);
      expect(gateway.simulation!.containsKey('showReservedRegions'), isFalse);
    });

    test('rotate with the rotation rule on a custom device', () async {
      await ready();
      await controller.selectPreset(duoView());
      // Without a preset to resolve from, the rule applies.
      final Map<String, Object?> sim = Map<String, Object?>.from(
        gateway.simulation!,
      )..remove('presetId');
      gateway.simulation = sim;
      await controller.refresh();
      await controller.setOrientation('landscape');
      final List<Object?> regions =
          gateway.simulation!['reservedRegions']! as List<Object?>;
      final Map<String, Object?> fold = regions
          .cast<Map<String, Object?>>()
          .singleWhere((r) => r['kind'] == 'division');
      expect(fold['bounds'], <String, Object?>{
        'left': 455.5,
        'top': 0.0,
        'right': 495.5,
        'bottom': 669.0,
      });
      expect(fold['margins'], <String, Object?>{
        'left': 20,
        'top': 0,
        'right': 20,
        'bottom': 0,
      });
    });
  });
}
