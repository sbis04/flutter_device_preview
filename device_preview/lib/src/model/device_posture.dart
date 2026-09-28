/// How a foldable device is being held — which of its screens is in use and
/// whether its hinge is flat or bent.
///
/// Lives in the model layer, beside [DeviceKind], because both a preset (which
/// postures it supports) and a simulation (which one it currently shows)
/// carry it.
///
/// The three postures are the ones both platforms name:
///
/// | Posture | Android (Jetpack WindowManager) | iOS 27.1 (`UIHinge.Status`) |
/// |---|---|---|
/// | [open] | `FoldingFeature.State.FLAT` | `fullyOpen` |
/// | [halfOpened] | `FoldingFeature.State.HALF_OPENED` | `partiallyOpen` |
/// | [closed] | the app moves to the cover display, which reports no fold | `closed` |
///
/// What an app observes in each posture is the device's business, not this
/// enum's: a preset describes it posture by posture (`DevicePreset.postures`
/// in `package:device_preview/presets.dart`).
enum DevicePosture {
  /// Fully open: the large inner display, hinge flat.
  open,

  /// Partially open — the tabletop or book pose: still the inner display, but
  /// the hinge is bent, so a fold divides the screen.
  halfOpened,

  /// Folded shut: the app runs on the cover (outer) display.
  closed,
}
