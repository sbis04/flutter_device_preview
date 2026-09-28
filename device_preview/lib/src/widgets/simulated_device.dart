import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/simulation.dart';
import 'device_preview_frame.dart';

/// A simulated device as an ordinary widget: [child] laid out on the
/// device's screen, inside its body, with the [MediaQuery] the device would
/// give it.
///
/// Where [DevicePreview] simulates a device for the **whole app** — at the
/// binding, so every `MediaQuery`, `View.of` and platform read agrees — this
/// widget draws one device **inside** another app's layout: a design tool's
/// canvas, a gallery of screens, a golden that frames a single widget.
/// Nothing reaches the platform; only the subtree below sees the device.
///
/// ```dart
/// SimulatedDevice(
///   simulation: DevicePresets.iPhoneDuo.resolve(
///     posture: DevicePosture.closed,
///   ),
///   child: const MyScreen(),
/// )
/// ```
///
/// The widget's natural size is [DeviceSimulation.contentBounds] — the
/// screen grown to include the body, rotated with the orientation — in
/// simulated logical pixels ([sizeOf]). It **fits** the constraints it is
/// given, like a `FittedBox` with [BoxFit.contain]: at its natural size when
/// there is room, scaled down when there is not, scaled exactly when the
/// parent imposes a size — `SizedBox.fromSize(size: sizeOf(s) * zoom)` is a
/// zoom control. The child always lays out at the simulated screen size,
/// whatever the scale.
///
/// What the child's [MediaQuery] carries, derived from the ambient one:
///
/// * `size`, `devicePixelRatio`, `padding`, `viewPadding` and
///   `systemGestureInsets` of the simulated device;
/// * `viewInsets.bottom` = [DeviceSimulation.keyboardInset] (a raised
///   simulated keyboard), with the bottom safe area collapsing under it the
///   way the engines collapse it;
/// * `displayFeatures` = [DeviceSimulation.displayFeatures] — what the
///   device's platform reports (none on iOS, a fold on an Android foldable);
/// * `platformBrightness`, `textScaler`, `alwaysUse24HourFormat` when the
///   simulation overrides them.
///
/// The frame, system UI (unless [DeviceSimulation.showSystemUi] is false),
/// keyboard band, fold creases and reserved region overlay are painted
/// exactly as under [DevicePreview] — by the same render object.
class SimulatedDevice extends StatefulWidget {
  /// Draws [child] on the device [simulation] describes.
  ///
  /// [simulation] must simulate metrics ([DeviceSimulation.simulatesMetrics]):
  /// a preset's `resolve()` does.
  const SimulatedDevice({
    super.key,
    required this.simulation,
    required this.child,
    this.showFrame = true,
    this.overlayStyle,
  });

  /// The device, orientation and posture to draw — typically
  /// `DevicePreset.resolve(orientation: …, posture: …)`.
  final DeviceSimulation simulation;

  /// The content of the screen.
  final Widget child;

  /// Whether the device body is drawn around the screen. When false the
  /// widget is exactly the screen — clipped to its outline, with its system
  /// UI — and sizes to [DeviceSimulation.screenSize].
  final bool showFrame;

  /// The system overlay style tinting the simulated status bar, or null to
  /// derive it from the simulated brightness.
  final SystemUiOverlayStyle? overlayStyle;

  /// The size this widget lays out at for [simulation]: the content bounds
  /// with the frame, the screen size without it.
  static ui.Size sizeOf(DeviceSimulation simulation, {bool showFrame = true}) {
    return showFrame
        ? simulation.contentBounds.size
        : (simulation.screenSize ?? ui.Size.zero);
  }

  /// Where the screen sits inside this widget, for [simulation] — the rect
  /// the child occupies, in this widget's coordinates.
  static ui.Rect screenRectOf(
    DeviceSimulation simulation, {
    bool showFrame = true,
  }) {
    final ui.Size screen = simulation.screenSize ?? ui.Size.zero;
    if (!showFrame) {
      return ui.Offset.zero & screen;
    }
    return (-simulation.contentBounds.topLeft) & screen;
  }

  @override
  State<SimulatedDevice> createState() => _SimulatedDeviceState();
}

class _SimulatedDeviceState extends State<SimulatedDevice> {
  late final ValueNotifier<DeviceSimulation?> _simulation =
      ValueNotifier<DeviceSimulation?>(_effective);
  late final ValueNotifier<SystemUiOverlayStyle?> _overlayStyle =
      ValueNotifier<SystemUiOverlayStyle?>(widget.overlayStyle);

  DeviceSimulation get _effective => widget.showFrame
      ? widget.simulation
      : widget.simulation.copyWith(frame: _screenOnly(widget.simulation));

  /// Without the body, the screen outline still clips.
  static Object? _screenOnly(DeviceSimulation simulation) {
    final frame = simulation.frame;
    if (frame == null || frame.screenPath.isEmpty) {
      return null;
    }
    return frame.copyWithoutBody();
  }

  @override
  void didUpdateWidget(SimulatedDevice oldWidget) {
    super.didUpdateWidget(oldWidget);
    _simulation.value = _effective;
    _overlayStyle.value = widget.overlayStyle;
  }

  @override
  void dispose() {
    _simulation.dispose();
    _overlayStyle.dispose();
    super.dispose();
  }

  MediaQueryData _mediaQuery(BuildContext context) {
    final DeviceSimulation s = widget.simulation;
    final MediaQueryData ambient =
        MediaQuery.maybeOf(context) ?? const MediaQueryData();
    final EdgeInsets viewPadding =
        s.viewPadding ?? s.padding ?? EdgeInsets.zero;
    final EdgeInsets padding = s.padding ?? viewPadding;
    final double keyboard = s.keyboardInset ?? 0;
    return ambient.copyWith(
      size: s.screenSize,
      devicePixelRatio: s.devicePixelRatio ?? ambient.devicePixelRatio,
      viewPadding: viewPadding,
      // A raised keyboard consumes the bottom safe area, as on the device.
      padding: padding.copyWith(bottom: math.max(0, padding.bottom - keyboard)),
      viewInsets: EdgeInsets.only(bottom: keyboard),
      systemGestureInsets: s.systemGestureInsets ?? EdgeInsets.zero,
      displayFeatures: <ui.DisplayFeature>[
        for (final SimulatedDisplayFeature f
            in s.displayFeatures ?? const <SimulatedDisplayFeature>[])
          ui.DisplayFeature(bounds: f.bounds, type: f.type, state: f.state),
      ],
      platformBrightness: s.platformBrightness ?? ambient.platformBrightness,
      textScaler: s.textScaleFactor == null
          ? ambient.textScaler
          : TextScaler.linear(s.textScaleFactor!),
      alwaysUse24HourFormat:
          s.alwaysUse24HourFormat ?? ambient.alwaysUse24HourFormat,
    );
  }

  @override
  Widget build(BuildContext context) {
    final DeviceSimulation s = widget.simulation;
    assert(
      s.simulatesMetrics,
      'SimulatedDevice needs a simulation with a screenSize — resolve a '
      'DevicePreset, or set DeviceSimulation.screenSize.',
    );
    final ui.Size size = SimulatedDevice.sizeOf(s, showFrame: widget.showFrame);
    final ui.Rect screen = SimulatedDevice.screenRectOf(
      s,
      showFrame: widget.showFrame,
    );
    return FittedBox(
      child: SizedBox.fromSize(
        size: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fromRect(
              rect: screen,
              child: DevicePreviewFrame(
                simulation: _simulation,
                overlayStyle: _overlayStyle,
                child: MediaQuery(
                  data: _mediaQuery(context),
                  child: widget.child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
