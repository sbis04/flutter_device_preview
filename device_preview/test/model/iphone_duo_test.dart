import 'dart:ui' as ui;

import 'package:device_preview/device_preview.dart';
import 'package:device_preview/presets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a Flutter 3.47.5 app reports on the iPhone Duo simulator (iOS 27.1,
/// Xcode 27.1), pose by pose: `MediaQuery.size`, `viewPadding` and the
/// settled `viewInsets.bottom` with the stock keyboard up. Landscape is
/// `UIInterfaceOrientation.landscapeRight` — the device's top edge on the
/// left, the quarter turn every preset's frame rotates by.
///
/// `displayFeatures` was empty and `systemGestureInsets` zero in every
/// pose, and the device pixel ratio 3.
const Map<DevicePosture, Map<Orientation, (ui.Size, EdgeInsets, double)>>
kMeasured = <DevicePosture, Map<Orientation, (ui.Size, EdgeInsets, double)>>{
  DevicePosture.open: <Orientation, (ui.Size, EdgeInsets, double)>{
    Orientation.portrait: (
      ui.Size(669, 951),
      EdgeInsets.only(top: 82, bottom: 34),
      350,
    ),
    Orientation.landscape: (
      ui.Size(951, 669),
      EdgeInsets.only(right: 84, bottom: 34),
      264,
    ),
  },
  DevicePosture.halfOpened: <Orientation, (ui.Size, EdgeInsets, double)>{
    // The keyboard splits around the fold, and grows.
    Orientation.portrait: (
      ui.Size(669, 951),
      EdgeInsets.only(top: 82, bottom: 34),
      495.5,
    ),
    Orientation.landscape: (
      ui.Size(951, 669),
      EdgeInsets.only(right: 84, bottom: 34),
      264,
    ),
  },
  DevicePosture.closed: <Orientation, (ui.Size, EdgeInsets, double)>{
    Orientation.portrait: (
      ui.Size(466, 678),
      EdgeInsets.only(right: 84, bottom: 34),
      289,
    ),
    Orientation.landscape: (
      ui.Size(678, 466),
      EdgeInsets.only(left: 84, bottom: 34),
      230,
    ),
  },
};

void main() {
  const DevicePreset duo = DevicePresets.iPhoneDuo;

  group('iPhone Duo preset', () {
    test('is an iOS foldable with every posture', () {
      expect(duo.id, 'apple-iphone-duo');
      expect(duo.platform, TargetPlatform.iOS);
      expect(duo.kind, DeviceKind.foldable);
      expect(duo.hasPostures, isTrue);
      expect(duo.supportedPostures, <DevicePosture>[
        DevicePosture.open,
        DevicePosture.halfOpened,
        DevicePosture.closed,
      ]);
      expect(DevicePresets.byId('apple-iphone-duo'), same(duo));
    });

    for (final MapEntry<DevicePosture,
            Map<Orientation, (ui.Size, EdgeInsets, double)>> posture
        in kMeasured.entries) {
      for (final MapEntry<Orientation, (ui.Size, EdgeInsets, double)> pose
          in posture.value.entries) {
        test('resolves ${posture.key.name} ${pose.key.name} to the metrics '
            'the device reports', () {
          final (ui.Size size, EdgeInsets padding, double keyboard) =
              pose.value;
          final DeviceSimulation simulation = duo.resolve(
            orientation: pose.key,
            posture: posture.key,
          );
          expect(simulation.posture, posture.key);
          expect(simulation.orientation, pose.key);
          expect(simulation.screenSize, size);
          expect(simulation.devicePixelRatio, 3);
          expect(simulation.padding, padding);
          expect(simulation.viewPadding, padding);
          expect(simulation.systemGestureInsets, EdgeInsets.zero);
          // Faithful to Flutter's iOS embedder: never a display feature.
          expect(simulation.displayFeatures, isNull);
          expect(
            duo.keyboardHeight(pose.key, posture: posture.key),
            keyboard,
          );
        });
      }
    }

    test('the fold is a division that is only active half-opened', () {
      SimulatedReservedRegion fold(DevicePosture posture, Orientation o) =>
          duo
              .resolve(orientation: o, posture: posture)
              .reservedRegions!
              .singleWhere(
                (SimulatedReservedRegion r) =>
                    r.kind == ReservedRegionKind.division,
              );
      for (final Orientation o in Orientation.values) {
        expect(fold(DevicePosture.open, o).isActive, isFalse);
        expect(fold(DevicePosture.halfOpened, o).isActive, isTrue);
      }
      // 40 pt wide including 20 pt margins, the crease at mid-height in
      // portrait and at mid-width in landscape.
      final SimulatedReservedRegion portrait = fold(
        DevicePosture.halfOpened,
        Orientation.portrait,
      );
      expect(portrait.bounds, const ui.Rect.fromLTRB(0, 455.5, 669, 495.5));
      expect(portrait.margins, const EdgeInsets.only(top: 20, bottom: 20));
      expect(portrait.core, const ui.Rect.fromLTRB(0, 475.5, 669, 475.5));
      final SimulatedReservedRegion landscape = fold(
        DevicePosture.halfOpened,
        Orientation.landscape,
      );
      expect(landscape.core.left, 951 / 2);
      expect(landscape.core.width, 0);
      // Geometry the hardware turns with matches the quarter turn.
      expect(portrait.rotatedToLandscape(669), landscape);
    });

    test('the closed posture has no fold, only the cover camera and the '
        'status column', () {
      final List<SimulatedReservedRegion> regions = duo
          .resolve(posture: DevicePosture.closed)
          .reservedRegions!;
      expect(
        regions.map((SimulatedReservedRegion r) => r.kind),
        everyElement(ReservedRegionKind.occlusion),
      );
      expect(regions.every((SimulatedReservedRegion r) => r.isActive), isTrue);
      // The camera: a 37 pt disc 29.33 pt from the top and right edges.
      final SimulatedReservedRegion camera = regions.first;
      expect(camera.bounds.width, closeTo(37, 0.01));
      expect(466 - camera.bounds.right, closeTo(29.33, 0.01));
    });

    test('the status column stays on the right of the open display in '
        'landscape instead of turning with the hardware', () {
      final SimulatedReservedRegion portrait = duo
          .resolve()
          .reservedRegions!
          .first;
      final SimulatedReservedRegion landscape = duo
          .resolve(orientation: Orientation.landscape)
          .reservedRegions!
          .first;
      expect(portrait.bounds, const ui.Rect.fromLTRB(535, 0, 669, 82));
      expect(landscape.bounds, const ui.Rect.fromLTRB(867, 0, 951, 120));
      expect(portrait.rotatedToLandscape(669), isNot(landscape));
    });

    test('draws its status bar on top in portrait and down the side where '
        'iOS puts it', () {
      final SystemUiSimulation open = duo.resolve().systemUi!;
      expect(open.platform, TargetPlatform.iOS);
      expect(open.statusBar!.trailing, isNotEmpty);
      expect(open.sideBar!.leading, isNotEmpty);
      final SystemUiSimulation closed = duo
          .resolve(posture: DevicePosture.closed)
          .systemUi!;
      expect(closed.platform, TargetPlatform.iOS);
      expect(closed.statusBar, isNull);
      expect(closed.sideBar!.leading, isNotEmpty);
      // iOS 27 draws no home indicator on the Duo, open or closed — the
      // 34 pt bottom inset is all there is.
      expect(closed.navigationBar, isNull);
      expect(open.navigationBar, isNull);
    });

    test('each posture has its own frame around its own screen', () {
      final DeviceFrame inner = duo.resolve().frame!;
      final DeviceFrame cover = duo
          .resolve(posture: DevicePosture.closed)
          .frame!;
      expect(inner, isNot(cover));
      // Half-open is the same screen, body and outline bent together at
      // the hinge — the bezel keeps its thickness into the V.
      final DeviceFrame bent = duo
          .resolve(posture: DevicePosture.halfOpened)
          .frame!;
      expect(bent, isNot(inner));
      expect(bent.size, inner.size);
      expect(bent.screenOffset, inner.screenOffset);
      expect(bent.screenPath, isNot(inner.screenPath));
      // The outline pinches in at the fold (mid-height), not at the top.
      expect(bent.screenPath, contains('L 10,475.5'));
      expect(bent.screenPath, contains('L 659,475.5'));
      // Screens sit inside their bodies.
      expect(inner.size.width, greaterThan(669));
      expect(cover.size.width, greaterThan(466));
      // The cover's bezel is wider along the hinge (left) than opposite.
      expect(
        cover.screenOffset.dx,
        greaterThan(cover.size.width - 466 - cover.screenOffset.dx),
      );
      // The cover camera is a hole in the screen outline.
      expect(cover.screenPath.split('M').length, greaterThan(2));
    });

    test('round-trips through JSON', () {
      expect(DevicePreset.fromJson(duo.toJson()), duo);
      final DevicePreset closed = duo.forPosture(DevicePosture.closed);
      expect(DevicePreset.fromJson(closed.toJson()), closed);
    });
  });

  group('DevicePreset.forPosture', () {
    const DevicePreset book = DevicePreset(
      id: 'book',
      name: 'Book',
      platform: TargetPlatform.android,
      kind: DeviceKind.foldable,
      portraitSize: ui.Size(800, 900),
      devicePixelRatio: 2,
      portraitPadding: EdgeInsets.only(top: 30, bottom: 20),
      landscapePadding: EdgeInsets.only(top: 30, bottom: 20),
      systemGestureInsets: EdgeInsets.only(left: 10, right: 10),
      portraitKeyboardHeight: 300,
      landscapeKeyboardHeight: 200,
      frame: DeviceFrame(size: ui.Size(840, 940)),
      systemUi: SystemUiSimulation(
        navigationBar: SystemUiBar(center: '<svg viewBox="0 0 10 2"/>'),
        // Spelled out: JSON decoding stamps the device's platform on bars
        // that do not name one.
        platform: TargetPlatform.android,
      ),
      displayFeatures: <SimulatedDisplayFeature>[
        SimulatedDisplayFeature(
          bounds: ui.Rect.fromLTRB(400, 0, 400, 900),
          type: ui.DisplayFeatureType.fold,
          state: ui.DisplayFeatureState.postureFlat,
        ),
      ],
      portraitReservedRegions: <SimulatedReservedRegion>[
        SimulatedReservedRegion(
          kind: ReservedRegionKind.division,
          bounds: ui.Rect.fromLTRB(390, 0, 410, 900),
          margins: EdgeInsets.only(left: 10, right: 10),
          isActive: false,
        ),
      ],
      postures: <DevicePosture, DevicePostureVariant>{
        DevicePosture.halfOpened: DevicePostureVariant(
          portraitKeyboardHeight: 320,
        ),
        DevicePosture.closed: DevicePostureVariant(
          portraitSize: ui.Size(400, 880),
          portraitPadding: EdgeInsets.only(top: 24),
        ),
      },
    );

    test('open is the preset itself', () {
      expect(book.forPosture(DevicePosture.open), same(book));
    });

    test('half-opened keeps the screen and bends its fold', () {
      final DevicePreset half = book.forPosture(DevicePosture.halfOpened);
      expect(half.portraitSize, book.portraitSize);
      expect(half.portraitPadding, book.portraitPadding);
      expect(half.landscapePadding, book.landscapePadding);
      expect(half.systemGestureInsets, book.systemGestureInsets);
      expect(half.frame, book.frame);
      expect(half.portraitKeyboardHeight, 320);
      expect(half.landscapeKeyboardHeight, 200);
      expect(
        half.displayFeatures.single.state,
        ui.DisplayFeatureState.postureHalfOpened,
      );
      expect(half.displayFeatures.single.bounds, book.displayFeatures.single.bounds);
      expect(half.portraitReservedRegions.single.isActive, isTrue);
      // The snapshot describes one screen.
      expect(half.hasPostures, isFalse);
      expect(half.id, book.id);
    });

    test('closed is another screen: nothing screen-bound is inherited', () {
      final DevicePreset closed = book.forPosture(DevicePosture.closed);
      expect(closed.portraitSize, const ui.Size(400, 880));
      expect(closed.portraitPadding, const EdgeInsets.only(top: 24));
      // Landscape follows the rotation rule of its own portrait padding,
      // never the open screen's explicit landscape padding.
      expect(closed.landscapePadding, isNull);
      expect(
        closed.resolve(orientation: Orientation.landscape).padding,
        const EdgeInsets.only(left: 24, right: 24),
      );
      expect(closed.systemGestureInsets, EdgeInsets.zero);
      expect(closed.portraitKeyboardHeight, isNull);
      expect(closed.displayFeatures, isEmpty);
      expect(closed.portraitReservedRegions, isEmpty);
      expect(closed.frame, isNull);
      // Properties of the device itself carry over.
      expect(closed.devicePixelRatio, 2);
      expect(closed.systemUi, book.systemUi);
      expect(closed.platform, book.platform);
    });

    test('an unsupported posture throws', () {
      expect(
        () => DevicePresets.iPhone17Pro.forPosture(DevicePosture.closed),
        throwsArgumentError,
      );
      expect(
        () => DevicePresets.iPhone17Pro.resolve(posture: DevicePosture.closed),
        throwsArgumentError,
      );
    });

    test('a device without postures resolves without one', () {
      expect(DevicePresets.iPhone17Pro.supportedPostures, isEmpty);
      expect(
        DevicePresets.iPhone17Pro.supportsPosture(DevicePosture.open),
        isTrue,
      );
      expect(DevicePresets.iPhone17Pro.resolve().posture, isNull);
      expect(DevicePresets.iPhone17Pro.resolve().reservedRegions, isNull);
    });

    test('JSON rejects an "open" posture entry', () {
      final Map<String, Object?> json = book.toJson()
        ..['postures'] = <String, Object?>{'open': <String, Object?>{}};
      expect(() => DevicePreset.fromJson(json), throwsFormatException);
    });

    test('JSON round-trips postures and reserved regions', () {
      expect(DevicePreset.fromJson(book.toJson()), book);
    });
  });

  group('SimulatedReservedRegion', () {
    const SimulatedReservedRegion region = SimulatedReservedRegion(
      kind: ReservedRegionKind.division,
      bounds: ui.Rect.fromLTRB(10, 100, 50, 140),
      margins: EdgeInsets.fromLTRB(1, 2, 3, 4),
      isActive: false,
    );

    test('rotation is its own inverse, margins included', () {
      final SimulatedReservedRegion landscape = region.rotatedToLandscape(200);
      expect(landscape.bounds, const ui.Rect.fromLTRB(100, 150, 140, 190));
      expect(landscape.margins, const EdgeInsets.fromLTRB(2, 3, 4, 1));
      expect(landscape.rotatedToPortrait(200), region);
    });

    test('JSON omits defaults and round-trips', () {
      expect(region.toJson(), <String, Object?>{
        'kind': 'division',
        'bounds': <String, Object?>{
          'left': 10.0,
          'top': 100.0,
          'right': 50.0,
          'bottom': 140.0,
        },
        'margins': <String, Object?>{
          'left': 1.0,
          'top': 2.0,
          'right': 3.0,
          'bottom': 4.0,
        },
        'active': false,
      });
      expect(SimulatedReservedRegion.fromJson(region.toJson()), region);
      const SimulatedReservedRegion plain = SimulatedReservedRegion(
        kind: ReservedRegionKind.occlusion,
        bounds: ui.Rect.fromLTRB(0, 0, 1, 1),
      );
      expect(plain.toJson().keys, <String>['kind', 'bounds']);
      expect(SimulatedReservedRegion.fromJson(plain.toJson()), plain);
    });

    test('a simulation carries regions, posture and the overlay switch', () {
      final DeviceSimulation simulation = duoSimulation();
      final DeviceSimulation decoded = DeviceSimulation.fromJson(
        simulation.toJson(),
      );
      expect(decoded, simulation);
      expect(decoded.posture, DevicePosture.closed);
      expect(decoded.showReservedRegions, isTrue);
      expect(simulation.copyWith(showReservedRegions: false).toJson(),
          isNot(contains('showReservedRegions')));
      expect(simulation.copyWith(posture: null).posture, isNull);
    });
  });
}

DeviceSimulation duoSimulation() => DevicePresets.iPhoneDuo
    .resolve(posture: DevicePosture.closed)
    .copyWith(showReservedRegions: true);
