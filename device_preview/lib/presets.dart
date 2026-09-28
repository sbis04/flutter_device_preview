/// Built-in device presets for `package:device_preview`.
///
/// A separate library so that unreferenced presets tree-shake away from apps
/// that never import it.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'src/model/device_frame.dart';
import 'src/model/device_kind.dart';
import 'src/model/device_posture.dart';
import 'src/model/json_utils.dart';
import 'src/model/simulation.dart';
import 'src/model/system_ui.dart';

export 'src/model/device_kind.dart';
export 'src/model/device_posture.dart';
export 'src/model/simulation.dart'
    show ReservedRegionKind, SimulatedDisplayFeature, SimulatedReservedRegion;

part 'src/presets.g.dart';

/// Description of a device: its metrics, and optionally the [frame] it is
/// drawn in.
///
/// Metric fields are expressed for the portrait orientation; landscape
/// values are either provided explicitly or derived by the documented
/// rotation rule (see [rotateToLandscape]).
///
/// A foldable describes its **open** posture with these fields and every
/// other posture it can take in [postures] — see [forPosture].
///
/// The built-in [DevicePresets] carry the complete spec — [frame] artwork
/// and [systemUi] included. They are generated from the device spec catalog
/// shared with the DevTools extension (`device_specs/` at the root of the
/// repository); [fromJson] decodes exactly that catalog format, so a spec
/// file can also be loaded directly by an app that wants a framed golden
/// test.
@immutable
class DevicePreset {
  /// Creates a device preset.
  const DevicePreset({
    required this.id,
    required this.name,
    required this.platform,
    required this.portraitSize,
    required this.devicePixelRatio,
    this.physicalSize,
    this.brand,
    this.year,
    this.frame,
    this.systemUi,
    this.portraitPadding = EdgeInsets.zero,
    this.portraitViewPadding,
    this.landscapePadding,
    this.landscapeViewPadding,
    this.systemGestureInsets = EdgeInsets.zero,
    this.portraitKeyboardHeight,
    this.landscapeKeyboardHeight,
    this.displayFeatures = const <SimulatedDisplayFeature>[],
    this.portraitReservedRegions = const <SimulatedReservedRegion>[],
    this.landscapeReservedRegions,
    this.postures = const <DevicePosture, DevicePostureVariant>{},
    this.kind = DeviceKind.phone,
  });

  /// Decodes a preset from the JSON produced by [toJson].
  ///
  /// Unknown keys are ignored; missing required keys or malformed values
  /// throw a [FormatException].
  factory DevicePreset.fromJson(Map<String, Object?> json) {
    final TargetPlatform platform = decodeEnum(
      json['platform'],
      TargetPlatform.values,
      'platform',
    );
    return DevicePreset(
      id: decodeString(json['id'], 'id'),
      name: decodeString(json['name'], 'name'),
      brand: json['brand'] == null
          ? null
          : decodeString(json['brand'], 'brand'),
      year: json['year'] == null ? null : decodeInt(json['year'], 'year'),
      platform: platform,
      frame: json['frame'] == null
          ? null
          : DeviceFrame.fromJson(decodeMap(json['frame'], 'frame')),
      systemUi: _decodeSystemUi(json['systemUi'], platform, 'systemUi'),
      portraitSize: decodeSize(json['portraitSize'], 'portraitSize'),
      devicePixelRatio: decodeDouble(
        json['devicePixelRatio'],
        'devicePixelRatio',
      ),
      physicalSize: json['physicalSize'] == null
          ? null
          : decodeSize(json['physicalSize'], 'physicalSize'),
      portraitPadding: json['portraitPadding'] == null
          ? EdgeInsets.zero
          : decodeEdgeInsets(json['portraitPadding'], 'portraitPadding'),
      portraitViewPadding: json['portraitViewPadding'] == null
          ? null
          : decodeEdgeInsets(
              json['portraitViewPadding'],
              'portraitViewPadding',
            ),
      landscapePadding: json['landscapePadding'] == null
          ? null
          : decodeEdgeInsets(json['landscapePadding'], 'landscapePadding'),
      landscapeViewPadding: json['landscapeViewPadding'] == null
          ? null
          : decodeEdgeInsets(
              json['landscapeViewPadding'],
              'landscapeViewPadding',
            ),
      systemGestureInsets: json['systemGestureInsets'] == null
          ? EdgeInsets.zero
          : decodeEdgeInsets(
              json['systemGestureInsets'],
              'systemGestureInsets',
            ),
      portraitKeyboardHeight: json['portraitKeyboardHeight'] == null
          ? null
          : decodeDouble(
              json['portraitKeyboardHeight'],
              'portraitKeyboardHeight',
            ),
      landscapeKeyboardHeight: json['landscapeKeyboardHeight'] == null
          ? null
          : decodeDouble(
              json['landscapeKeyboardHeight'],
              'landscapeKeyboardHeight',
            ),
      displayFeatures:
          _decodeFeatures(json['displayFeatures'], 'displayFeatures') ??
          const <SimulatedDisplayFeature>[],
      portraitReservedRegions:
          _decodeRegions(
            json['portraitReservedRegions'],
            'portraitReservedRegions',
          ) ??
          const <SimulatedReservedRegion>[],
      landscapeReservedRegions: _decodeRegions(
        json['landscapeReservedRegions'],
        'landscapeReservedRegions',
      ),
      postures: json['postures'] == null
          ? const <DevicePosture, DevicePostureVariant>{}
          : _decodePostures(json['postures'], platform),
      kind: json['kind'] == null
          ? DeviceKind.phone
          : decodeEnum(json['kind'], DeviceKind.values, 'kind'),
    );
  }

  /// Stable identifier, e.g. `'apple-iphone-16-pro'`.
  final String id;

  /// Human-readable name, e.g. `'iPhone 16 Pro'`.
  final String name;

  /// The manufacturer, e.g. `'Apple'`. Null when unspecified.
  final String? brand;

  /// The year the device was released, e.g. `2025`. Null when unspecified.
  ///
  /// Purely informational — nothing in the simulation depends on it. The
  /// DevTools picker shows it so that a catalog spanning several generations
  /// can be read at a glance.
  final int? year;

  /// The platform of the device.
  final TargetPlatform platform;

  /// The device's screen outline and body artwork, or null for a plain
  /// rectangular screen with no artwork.
  final DeviceFrame? frame;

  /// The device's decorative system UI (status bar, gesture pill), or null
  /// to leave the screen bare.
  final SystemUiSimulation? systemUi;

  /// The logical screen size in portrait orientation.
  ///
  /// Desktop presets use their natural window dimensions here (typically
  /// wider than tall).
  final ui.Size portraitSize;

  /// The device pixel ratio.
  final double devicePixelRatio;

  /// The panel's resolution in physical pixels, portrait, when it is not
  /// [portraitSize] × [devicePixelRatio] — a screen the device renders at
  /// that scale and then downsamples, like the iPhone Duo's inner display
  /// (2007 × 2853 rendered, a 1878 × 2670 panel). Null when the panel is
  /// exactly the rendered size; [panelSize] answers either way.
  final ui.Size? physicalSize;

  /// The panel's resolution in physical pixels, portrait: [physicalSize],
  /// or [portraitSize] × [devicePixelRatio].
  ui.Size get panelSize => physicalSize ?? portraitSize * devicePixelRatio;

  /// The portrait safe-area padding, in logical pixels.
  final EdgeInsets portraitPadding;

  /// The portrait view padding; defaults to [portraitPadding] when null.
  final EdgeInsets? portraitViewPadding;

  /// The landscape safe-area padding; when null, derived from
  /// [portraitPadding] by the rotation rule ([rotateToLandscape]).
  final EdgeInsets? landscapePadding;

  /// The landscape view padding; when null, follows [landscapePadding], or
  /// the rotation rule applied to the effective portrait view padding.
  final EdgeInsets? landscapeViewPadding;

  /// The system gesture insets, in logical pixels.
  final EdgeInsets systemGestureInsets;

  /// The height the device's software keyboard covers in portrait, in
  /// logical pixels, or null when the device has no software keyboard (a
  /// desktop window) or its height has not been measured.
  ///
  /// Measured on the device itself, with its stock keyboard and no
  /// predictive-text row toggled off. Showing it is a per-simulation choice
  /// ([DeviceSimulation.keyboardInset]), so a preset never turns it on by
  /// itself: [resolve] leaves the keyboard hidden.
  final double? portraitKeyboardHeight;

  /// The height the device's software keyboard covers in landscape, in
  /// logical pixels. See [portraitKeyboardHeight].
  ///
  /// Keyboards are shorter in landscape and the ratio is not derivable from
  /// the portrait height, so there is no rotation rule: a device that
  /// declares one height and not the other simply has no keyboard in the
  /// other orientation.
  final double? landscapeKeyboardHeight;

  /// Display features (folds, hinges, cutouts), in portrait logical pixels.
  ///
  /// What the device's *platform* reports to a Flutter app as
  /// `MediaQuery.displayFeatures` — which is not always what the hardware
  /// has: Flutter's iOS embedder reports none at all, so an iPhone Duo
  /// declares no display feature even though it folds. Its fold lives in
  /// [portraitReservedRegions] instead.
  final List<SimulatedDisplayFeature> displayFeatures;

  /// The screen areas the device reserves in portrait — cameras, a side
  /// status bar, a fold — in portrait logical pixels. See
  /// [DeviceSimulation.reservedRegions] for what they are and why the app
  /// never sees them.
  final List<SimulatedReservedRegion> portraitReservedRegions;

  /// The reserved regions in landscape, in landscape logical pixels; when
  /// null, [portraitReservedRegions] mapped through the 90° rotation
  /// ([SimulatedReservedRegion.rotatedToLandscape]).
  ///
  /// Declare them whenever the system re-lays a region out on rotation
  /// rather than turning it with the hardware — the iPhone Duo's status
  /// column stays on the right in both orientations.
  final List<SimulatedReservedRegion>? landscapeReservedRegions;

  /// The postures this device can take besides [DevicePosture.open], each
  /// described by how it differs from the open one; empty for a device that
  /// does not fold.
  ///
  /// The fields of the preset itself are the open posture. See
  /// [DevicePostureVariant] for how a posture inherits from them and
  /// [forPosture] for the resolved result.
  final Map<DevicePosture, DevicePostureVariant> postures;

  /// The broad category of the device.
  final DeviceKind kind;

  /// Whether this device can take several postures — whether it folds in a
  /// way the simulation can switch.
  bool get hasPostures => postures.isNotEmpty;

  /// The postures this device supports, [DevicePosture.open] first; empty
  /// when it has no postures at all.
  List<DevicePosture> get supportedPostures => postures.isEmpty
      ? const <DevicePosture>[]
      : <DevicePosture>[
          DevicePosture.open,
          for (final DevicePosture posture in DevicePosture.values)
            if (posture != DevicePosture.open && postures.containsKey(posture))
              posture,
        ];

  /// Whether [posture] is one this device can take. Every device can take
  /// [DevicePosture.open] — for a device that does not fold, it is simply
  /// the only one.
  bool supportsPosture(DevicePosture posture) =>
      posture == DevicePosture.open || postures.containsKey(posture);

  /// The documented rotation rule for deriving landscape safe areas from
  /// portrait ones:
  ///
  /// ```
  /// landscape = EdgeInsets.only(
  ///   left: portrait.top, right: portrait.top, bottom: portrait.bottom)
  /// ```
  ///
  /// The notch/status area is mirrored to both sides and the home indicator
  /// is kept at the bottom.
  static EdgeInsets rotateToLandscape(EdgeInsets portrait) => EdgeInsets.only(
    left: portrait.top,
    right: portrait.top,
    bottom: portrait.bottom,
  );

  /// The keyboard height for [orientation] — and, on a foldable, [posture] —
  /// or null when this device declares none.
  ///
  /// The value to pass to `DeviceSimulation.copyWith(keyboardInset: …)` to
  /// raise this device's keyboard:
  ///
  /// ```dart
  /// await c.update(
  ///   (s) => s.copyWith(keyboardInset: preset.keyboardHeight(s.orientation)),
  /// );
  /// ```
  double? keyboardHeight(
    Orientation orientation, {
    DevicePosture posture = DevicePosture.open,
  }) {
    final DevicePreset screen = posture == DevicePosture.open
        ? this
        : forPosture(posture);
    return orientation == Orientation.portrait
        ? screen.portraitKeyboardHeight
        : screen.landscapeKeyboardHeight;
  }

  /// This device as it is in [posture]: a preset with the same [id],
  /// [name] and [platform] and the metric and appearance fields of that
  /// posture.
  ///
  /// [DevicePosture.open] returns this preset itself. Any other posture
  /// merges its [DevicePostureVariant] over this preset by the rules that
  /// class documents, into a snapshot that has no [postures] of its own —
  /// it describes one screen, so it cannot be asked for another. Throws an
  /// [ArgumentError] when the device does not support [posture].
  DevicePreset forPosture(DevicePosture posture) {
    if (posture == DevicePosture.open) {
      return this;
    }
    final DevicePostureVariant? variant = postures[posture];
    if (variant == null) {
      throw ArgumentError.value(
        posture,
        'posture',
        '$name does not support this posture',
      );
    }
    // A posture with a size of its own is another screen: nothing bound to
    // the open screen's geometry carries over.
    final bool sameScreen = variant.portraitSize == null;
    final bool halfOpened = posture == DevicePosture.halfOpened;
    final bool ownPadding = variant.portraitPadding != null;
    final bool ownViewPadding = variant.portraitViewPadding != null;
    final bool ownRegions = variant.portraitReservedRegions != null;
    return DevicePreset(
      id: id,
      name: name,
      brand: brand,
      year: year,
      platform: platform,
      kind: kind,
      portraitSize: variant.portraitSize ?? portraitSize,
      devicePixelRatio: variant.devicePixelRatio ?? devicePixelRatio,
      physicalSize: variant.physicalSize ?? (sameScreen ? physicalSize : null),
      frame: variant.frame ?? (sameScreen ? frame : null),
      systemUi: variant.systemUi ?? systemUi,
      portraitPadding:
          variant.portraitPadding ??
          (sameScreen ? portraitPadding : EdgeInsets.zero),
      // The landscape half of a pair follows its portrait half: a posture
      // that declares its own portrait padding takes its landscape padding
      // from itself (or the rotation rule), never from another layout.
      landscapePadding: ownPadding || !sameScreen
          ? variant.landscapePadding
          : (variant.landscapePadding ?? landscapePadding),
      portraitViewPadding:
          variant.portraitViewPadding ??
          (sameScreen && !ownPadding ? portraitViewPadding : null),
      landscapeViewPadding: ownViewPadding || ownPadding || !sameScreen
          ? variant.landscapeViewPadding
          : (variant.landscapeViewPadding ?? landscapeViewPadding),
      systemGestureInsets:
          variant.systemGestureInsets ??
          (sameScreen ? systemGestureInsets : EdgeInsets.zero),
      portraitKeyboardHeight:
          variant.portraitKeyboardHeight ??
          (sameScreen ? portraitKeyboardHeight : null),
      landscapeKeyboardHeight:
          variant.landscapeKeyboardHeight ??
          (sameScreen ? landscapeKeyboardHeight : null),
      displayFeatures:
          variant.displayFeatures ??
          (!sameScreen
              ? const <SimulatedDisplayFeature>[]
              : halfOpened
              ? _halfOpenedFeatures(displayFeatures)
              : displayFeatures),
      portraitReservedRegions:
          variant.portraitReservedRegions ??
          (!sameScreen
              ? const <SimulatedReservedRegion>[]
              : halfOpened
              ? _activateDivisions(portraitReservedRegions)
              : portraitReservedRegions),
      landscapeReservedRegions: ownRegions || !sameScreen
          ? variant.landscapeReservedRegions
          : (variant.landscapeReservedRegions ??
                (halfOpened && landscapeReservedRegions != null
                    ? _activateDivisions(landscapeReservedRegions!)
                    : landscapeReservedRegions)),
    );
  }

  /// A fold or hinge the platform reports flat is reported half-opened once
  /// the device bends — what Android's `FoldingFeature` does.
  static List<SimulatedDisplayFeature> _halfOpenedFeatures(
    List<SimulatedDisplayFeature> features,
  ) => List<SimulatedDisplayFeature>.unmodifiable(
    features.map(
      (SimulatedDisplayFeature f) =>
          (f.type == ui.DisplayFeatureType.fold ||
                  f.type == ui.DisplayFeatureType.hinge) &&
              f.state == ui.DisplayFeatureState.postureFlat
          ? SimulatedDisplayFeature(
              bounds: f.bounds,
              type: f.type,
              state: ui.DisplayFeatureState.postureHalfOpened,
            )
          : f,
    ),
  );

  /// A fold divides the screen only while the device is partially open —
  /// what iOS reports for the iPhone Duo's division region.
  static List<SimulatedReservedRegion> _activateDivisions(
    List<SimulatedReservedRegion> regions,
  ) => List<SimulatedReservedRegion>.unmodifiable(
    regions.map(
      (SimulatedReservedRegion r) =>
          r.kind == ReservedRegionKind.division ? r.withActive(true) : r,
    ),
  );

  /// Resolves this preset into a metrics-only [DeviceSimulation] with
  /// [DeviceSimulation.presetId] set.
  ///
  /// For [Orientation.landscape], the screen dimensions are swapped and the
  /// preset's explicit landscape safe areas are used when available;
  /// otherwise they are derived by [rotateToLandscape]. Display features
  /// (expressed in portrait coordinates) are mapped through the 90° rotation
  /// ([SimulatedDisplayFeature.rotatedToLandscape]) so hinge/fold geometry
  /// stays physically correct; reserved regions too, unless the preset
  /// declares [landscapeReservedRegions]. [systemGestureInsets]
  /// intentionally pass through unrotated: their edge semantics
  /// (back-gesture side edges, home area at the bottom) are
  /// orientation-invariant on real devices.
  ///
  /// A foldable resolves in [posture] ([forPosture]), which the simulation
  /// records as [DeviceSimulation.posture]; a device without postures leaves
  /// it null. Throws an [ArgumentError] for a posture the device does not
  /// support.
  DeviceSimulation resolve({
    Orientation orientation = Orientation.portrait,
    DevicePosture posture = DevicePosture.open,
  }) {
    return forPosture(
      posture,
    )._resolveScreen(orientation, hasPostures ? posture : null);
  }

  DeviceSimulation _resolveScreen(
    Orientation orientation,
    DevicePosture? posture,
  ) {
    final EdgeInsets effectivePortraitViewPadding =
        portraitViewPadding ?? portraitPadding;
    // The bars belong to the simulated device's operating system: stamp the
    // preset's platform so paint-time behavior (Android tints the bar
    // backgrounds from the app's `SystemUiOverlayStyle`, iOS never does)
    // follows the device rather than the host the app runs on.
    final SystemUiSimulation? resolvedSystemUi = systemUi == null
        ? null
        : (systemUi!.platform != null
              ? systemUi
              : systemUi!.withPlatform(platform));
    if (orientation == Orientation.portrait) {
      return DeviceSimulation(
        presetId: id,
        deviceKind: kind,
        posture: posture,
        screenSize: portraitSize,
        frame: frame,
        systemUi: resolvedSystemUi,
        devicePixelRatio: devicePixelRatio,
        padding: portraitPadding,
        viewPadding: effectivePortraitViewPadding,
        systemGestureInsets: systemGestureInsets,
        displayFeatures: displayFeatures.isEmpty ? null : displayFeatures,
        reservedRegions: portraitReservedRegions.isEmpty
            ? null
            : portraitReservedRegions,
      );
    }
    final EdgeInsets resolvedLandscapePadding =
        landscapePadding ?? rotateToLandscape(portraitPadding);
    final EdgeInsets resolvedLandscapeViewPadding =
        landscapeViewPadding ??
        landscapePadding ??
        rotateToLandscape(effectivePortraitViewPadding);
    final List<SimulatedReservedRegion> landscapeRegions =
        landscapeReservedRegions ??
        List<SimulatedReservedRegion>.unmodifiable(
          portraitReservedRegions.map(
            (SimulatedReservedRegion region) =>
                region.rotatedToLandscape(portraitSize.width),
          ),
        );
    return DeviceSimulation(
      presetId: id,
      deviceKind: kind,
      posture: posture,
      orientation: Orientation.landscape,
      screenSize: ui.Size(portraitSize.height, portraitSize.width),
      // Frames are described in portrait and rotated at paint time.
      frame: frame,
      // System bars follow the safe areas, which resolve() already rotated.
      systemUi: resolvedSystemUi,
      devicePixelRatio: devicePixelRatio,
      padding: resolvedLandscapePadding,
      viewPadding: resolvedLandscapeViewPadding,
      systemGestureInsets: systemGestureInsets,
      displayFeatures: displayFeatures.isEmpty
          ? null
          : List<SimulatedDisplayFeature>.unmodifiable(
              displayFeatures.map(
                (SimulatedDisplayFeature feature) =>
                    feature.rotatedToLandscape(portraitSize.width),
              ),
            ),
      reservedRegions: landscapeRegions.isEmpty ? null : landscapeRegions,
    );
  }

  /// Encodes this preset as JSON. Null fields are absent.
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    if (brand != null) 'brand': brand,
    if (year != null) 'year': year,
    'platform': platform.name,
    'kind': kind.name,
    'portraitSize': encodeSize(portraitSize),
    if (frame != null) 'frame': frame!.toJson(),
    if (systemUi != null) 'systemUi': systemUi!.toJson(),
    'devicePixelRatio': devicePixelRatio,
    if (physicalSize != null) 'physicalSize': encodeSize(physicalSize!),
    'portraitPadding': encodeEdgeInsets(portraitPadding),
    if (portraitViewPadding != null)
      'portraitViewPadding': encodeEdgeInsets(portraitViewPadding!),
    if (landscapePadding != null)
      'landscapePadding': encodeEdgeInsets(landscapePadding!),
    if (landscapeViewPadding != null)
      'landscapeViewPadding': encodeEdgeInsets(landscapeViewPadding!),
    'systemGestureInsets': encodeEdgeInsets(systemGestureInsets),
    if (portraitKeyboardHeight != null)
      'portraitKeyboardHeight': portraitKeyboardHeight,
    if (landscapeKeyboardHeight != null)
      'landscapeKeyboardHeight': landscapeKeyboardHeight,
    if (displayFeatures.isNotEmpty)
      'displayFeatures': displayFeatures
          .map((SimulatedDisplayFeature f) => f.toJson())
          .toList(),
    if (portraitReservedRegions.isNotEmpty)
      'portraitReservedRegions': portraitReservedRegions
          .map((SimulatedReservedRegion r) => r.toJson())
          .toList(),
    if (landscapeReservedRegions != null)
      'landscapeReservedRegions': landscapeReservedRegions!
          .map((SimulatedReservedRegion r) => r.toJson())
          .toList(),
    if (postures.isNotEmpty)
      'postures': <String, Object?>{
        for (final MapEntry<DevicePosture, DevicePostureVariant> entry
            in postures.entries)
          entry.key.name: entry.value.toJson(),
      },
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is DevicePreset &&
        other.id == id &&
        other.name == name &&
        other.brand == brand &&
        other.year == year &&
        other.platform == platform &&
        other.frame == frame &&
        other.systemUi == systemUi &&
        other.portraitSize == portraitSize &&
        other.devicePixelRatio == devicePixelRatio &&
        other.physicalSize == physicalSize &&
        other.portraitPadding == portraitPadding &&
        other.portraitViewPadding == portraitViewPadding &&
        other.landscapePadding == landscapePadding &&
        other.landscapeViewPadding == landscapeViewPadding &&
        other.systemGestureInsets == systemGestureInsets &&
        other.portraitKeyboardHeight == portraitKeyboardHeight &&
        other.landscapeKeyboardHeight == landscapeKeyboardHeight &&
        listEquals(other.displayFeatures, displayFeatures) &&
        listEquals(other.portraitReservedRegions, portraitReservedRegions) &&
        listEquals(other.landscapeReservedRegions, landscapeReservedRegions) &&
        mapEquals(other.postures, postures) &&
        other.kind == kind;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    id,
    name,
    brand,
    year,
    platform,
    frame,
    systemUi,
    portraitSize,
    devicePixelRatio,
    physicalSize,
    portraitPadding,
    portraitViewPadding,
    landscapePadding,
    landscapeViewPadding,
    systemGestureInsets,
    portraitKeyboardHeight,
    landscapeKeyboardHeight,
    Object.hashAll(displayFeatures),
    Object.hashAll(portraitReservedRegions),
    landscapeReservedRegions == null
        ? null
        : Object.hashAll(landscapeReservedRegions!),
    Object.hashAllUnordered(
      postures.entries.map(
        (MapEntry<DevicePosture, DevicePostureVariant> e) =>
            Object.hash(e.key, e.value),
      ),
    ),
    kind,
  ]);

  @override
  String toString() => 'DevicePreset($id, $name)';
}

/// How one posture of a foldable differs from its open posture — an entry of
/// [DevicePreset.postures].
///
/// Every field is optional: a null field is inherited from the preset, by
/// three rules.
///
/// * **Another screen.** A variant that declares its own [portraitSize] —
///   [DevicePosture.closed], which moves the app to the cover display —
///   inherits nothing bound to the open screen: safe areas, gesture insets,
///   keyboard heights, display features, reserved regions and the [frame]
///   start from scratch (zero, none, the rotation rule). Only
///   [devicePixelRatio] and [systemUi] — properties of the device rather
///   than of one panel — carry over.
/// * **The same screen.** A variant without a size —
///   [DevicePosture.halfOpened] — inherits everything and overrides what it
///   declares. Its folds and hinges report `postureHalfOpened`, and its
///   division regions become active, unless it declares those lists itself.
/// * **Pairs travel together.** A variant that declares a portrait padding,
///   view padding or reserved-region list takes the landscape half of that
///   pair from itself too — its own value, or the rotation rule — never
///   from the open posture's layout.
@immutable
class DevicePostureVariant {
  /// Creates a posture variant.
  const DevicePostureVariant({
    this.portraitSize,
    this.devicePixelRatio,
    this.physicalSize,
    this.frame,
    this.systemUi,
    this.portraitPadding,
    this.portraitViewPadding,
    this.landscapePadding,
    this.landscapeViewPadding,
    this.systemGestureInsets,
    this.portraitKeyboardHeight,
    this.landscapeKeyboardHeight,
    this.displayFeatures,
    this.portraitReservedRegions,
    this.landscapeReservedRegions,
  });

  /// Decodes a variant from the JSON produced by [toJson] — the same keys as
  /// a device spec's metric and appearance fields.
  ///
  /// [platform] is stamped onto a [systemUi] that does not name its own, as
  /// [DevicePreset.fromJson] does. Unknown keys are ignored.
  factory DevicePostureVariant.fromJson(
    Map<String, Object?> json, {
    TargetPlatform? platform,
  }) {
    EdgeInsets? insets(String key) =>
        json[key] == null ? null : decodeEdgeInsets(json[key], key);
    double? number(String key) =>
        json[key] == null ? null : decodeDouble(json[key], key);
    return DevicePostureVariant(
      portraitSize: json['portraitSize'] == null
          ? null
          : decodeSize(json['portraitSize'], 'portraitSize'),
      devicePixelRatio: number('devicePixelRatio'),
      physicalSize: json['physicalSize'] == null
          ? null
          : decodeSize(json['physicalSize'], 'physicalSize'),
      frame: json['frame'] == null
          ? null
          : DeviceFrame.fromJson(decodeMap(json['frame'], 'frame')),
      systemUi: _decodeSystemUi(json['systemUi'], platform, 'systemUi'),
      portraitPadding: insets('portraitPadding'),
      portraitViewPadding: insets('portraitViewPadding'),
      landscapePadding: insets('landscapePadding'),
      landscapeViewPadding: insets('landscapeViewPadding'),
      systemGestureInsets: insets('systemGestureInsets'),
      portraitKeyboardHeight: number('portraitKeyboardHeight'),
      landscapeKeyboardHeight: number('landscapeKeyboardHeight'),
      displayFeatures: _decodeFeatures(
        json['displayFeatures'],
        'displayFeatures',
      ),
      portraitReservedRegions: _decodeRegions(
        json['portraitReservedRegions'],
        'portraitReservedRegions',
      ),
      landscapeReservedRegions: _decodeRegions(
        json['landscapeReservedRegions'],
        'landscapeReservedRegions',
      ),
    );
  }

  /// See [DevicePreset.portraitSize]. Declaring it makes this posture
  /// another screen (see the class documentation).
  final ui.Size? portraitSize;

  /// See [DevicePreset.devicePixelRatio].
  final double? devicePixelRatio;

  /// See [DevicePreset.physicalSize]. A posture with its own [portraitSize]
  /// starts from none.
  final ui.Size? physicalSize;

  /// See [DevicePreset.frame].
  final DeviceFrame? frame;

  /// See [DevicePreset.systemUi].
  final SystemUiSimulation? systemUi;

  /// See [DevicePreset.portraitPadding].
  final EdgeInsets? portraitPadding;

  /// See [DevicePreset.portraitViewPadding].
  final EdgeInsets? portraitViewPadding;

  /// See [DevicePreset.landscapePadding].
  final EdgeInsets? landscapePadding;

  /// See [DevicePreset.landscapeViewPadding].
  final EdgeInsets? landscapeViewPadding;

  /// See [DevicePreset.systemGestureInsets].
  final EdgeInsets? systemGestureInsets;

  /// See [DevicePreset.portraitKeyboardHeight].
  final double? portraitKeyboardHeight;

  /// See [DevicePreset.landscapeKeyboardHeight].
  final double? landscapeKeyboardHeight;

  /// See [DevicePreset.displayFeatures].
  final List<SimulatedDisplayFeature>? displayFeatures;

  /// See [DevicePreset.portraitReservedRegions].
  final List<SimulatedReservedRegion>? portraitReservedRegions;

  /// See [DevicePreset.landscapeReservedRegions].
  final List<SimulatedReservedRegion>? landscapeReservedRegions;

  /// Encodes this variant as JSON. Null fields are absent.
  Map<String, Object?> toJson() => <String, Object?>{
    if (portraitSize != null) 'portraitSize': encodeSize(portraitSize!),
    if (devicePixelRatio != null) 'devicePixelRatio': devicePixelRatio,
    if (physicalSize != null) 'physicalSize': encodeSize(physicalSize!),
    if (frame != null) 'frame': frame!.toJson(),
    if (systemUi != null) 'systemUi': systemUi!.toJson(),
    if (portraitPadding != null)
      'portraitPadding': encodeEdgeInsets(portraitPadding!),
    if (portraitViewPadding != null)
      'portraitViewPadding': encodeEdgeInsets(portraitViewPadding!),
    if (landscapePadding != null)
      'landscapePadding': encodeEdgeInsets(landscapePadding!),
    if (landscapeViewPadding != null)
      'landscapeViewPadding': encodeEdgeInsets(landscapeViewPadding!),
    if (systemGestureInsets != null)
      'systemGestureInsets': encodeEdgeInsets(systemGestureInsets!),
    if (portraitKeyboardHeight != null)
      'portraitKeyboardHeight': portraitKeyboardHeight,
    if (landscapeKeyboardHeight != null)
      'landscapeKeyboardHeight': landscapeKeyboardHeight,
    if (displayFeatures != null)
      'displayFeatures': displayFeatures!
          .map((SimulatedDisplayFeature f) => f.toJson())
          .toList(),
    if (portraitReservedRegions != null)
      'portraitReservedRegions': portraitReservedRegions!
          .map((SimulatedReservedRegion r) => r.toJson())
          .toList(),
    if (landscapeReservedRegions != null)
      'landscapeReservedRegions': landscapeReservedRegions!
          .map((SimulatedReservedRegion r) => r.toJson())
          .toList(),
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is DevicePostureVariant &&
        other.portraitSize == portraitSize &&
        other.devicePixelRatio == devicePixelRatio &&
        other.frame == frame &&
        other.systemUi == systemUi &&
        other.portraitPadding == portraitPadding &&
        other.portraitViewPadding == portraitViewPadding &&
        other.landscapePadding == landscapePadding &&
        other.landscapeViewPadding == landscapeViewPadding &&
        other.systemGestureInsets == systemGestureInsets &&
        other.portraitKeyboardHeight == portraitKeyboardHeight &&
        other.landscapeKeyboardHeight == landscapeKeyboardHeight &&
        listEquals(other.displayFeatures, displayFeatures) &&
        listEquals(other.portraitReservedRegions, portraitReservedRegions) &&
        listEquals(other.landscapeReservedRegions, landscapeReservedRegions);
  }

  @override
  int get hashCode => Object.hash(
    portraitSize,
    devicePixelRatio,
    frame,
    systemUi,
    portraitPadding,
    portraitViewPadding,
    landscapePadding,
    landscapeViewPadding,
    systemGestureInsets,
    portraitKeyboardHeight,
    landscapeKeyboardHeight,
    displayFeatures == null ? null : Object.hashAll(displayFeatures!),
    portraitReservedRegions == null
        ? null
        : Object.hashAll(portraitReservedRegions!),
    landscapeReservedRegions == null
        ? null
        : Object.hashAll(landscapeReservedRegions!),
  );
}

/// Decodes a `systemUi` object, stamping [platform] onto bars that do not
/// name their own: paint-time behavior (Android tints bar backgrounds, iOS
/// never does) must follow the simulated device, not the app's host. Specs
/// in `device_specs/` rely on this — they never repeat the platform inside
/// `systemUi`.
SystemUiSimulation? _decodeSystemUi(
  Object? json,
  TargetPlatform? platform,
  String context,
) {
  if (json == null) {
    return null;
  }
  final SystemUiSimulation systemUi = SystemUiSimulation.fromJson(
    decodeMap(json, context),
  );
  return systemUi.platform == null && platform != null
      ? systemUi.withPlatform(platform)
      : systemUi;
}

List<SimulatedDisplayFeature>? _decodeFeatures(Object? json, String context) {
  if (json == null) {
    return null;
  }
  return List<SimulatedDisplayFeature>.unmodifiable(
    decodeList(json, context).map(
      (Object? e) =>
          SimulatedDisplayFeature.fromJson(decodeMap(e, '$context[]')),
    ),
  );
}

List<SimulatedReservedRegion>? _decodeRegions(Object? json, String context) {
  if (json == null) {
    return null;
  }
  return List<SimulatedReservedRegion>.unmodifiable(
    decodeList(json, context).map(
      (Object? e) =>
          SimulatedReservedRegion.fromJson(decodeMap(e, '$context[]')),
    ),
  );
}

Map<DevicePosture, DevicePostureVariant> _decodePostures(
  Object? json,
  TargetPlatform platform,
) {
  final Map<String, Object?> map = decodeMap(json, 'postures');
  final Map<DevicePosture, DevicePostureVariant> postures =
      <DevicePosture, DevicePostureVariant>{};
  for (final MapEntry<String, Object?> entry in map.entries) {
    final DevicePosture posture = decodeEnum(
      entry.key,
      DevicePosture.values,
      'postures key',
    );
    if (posture == DevicePosture.open) {
      throw const FormatException(
        'postures must not declare "open": the top-level fields are the open '
        'posture',
      );
    }
    postures[posture] = DevicePostureVariant.fromJson(
      decodeMap(entry.value, 'postures.${entry.key}'),
      platform: platform,
    );
  }
  return Map<DevicePosture, DevicePostureVariant>.unmodifiable(postures);
}
