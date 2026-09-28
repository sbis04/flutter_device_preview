// Posture probe for foldable iPhones (the iPhone Duo), run on a booted
// iOS 27.1+ simulator — see SKILL.md, "iPhone Duo".
//
// Unlike probe.swift it keeps running: on launch, on every UIHingeInteraction
// update and on every screen / orientation change it prints one
// `DUOPROBE {json}` line with the window size, scale, safe areas, the
// settled height of the stock keyboard, UIHinge status/angle and every
// reserved region UIKit reports (`reservedRegions(kind:options:
// .includeInactive)`, occlusions and divisions, with margins and active
// state). Change postures and rotate in Device Hub, read the lines.
//
// Launch with SIMCTL_CHILD_PASSIVE=1 to measure the current pose only: iOS
// refuses requestGeometryUpdate on the Duo's inner display, so landscape
// there has to come from a real rotation. Without it, each cycle also
// requests portrait and landscapeRight itself (fine on the cover).
//
// Built like probe.swift, but for iOS 27.1 and with a scene delegate — iOS 27
// terminates apps that do not adopt the UIScene life cycle:
//
//   SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path) xcrun swiftc \
//     -target arm64-apple-ios27.1-simulator posture_probe.swift -o Probe.app/Probe
//
// with probe.swift's Info.plist plus UIApplicationSceneManifest.
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication,
    configurationForConnecting session: UISceneSession,
    options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let c = UISceneConfiguration(name: "Default", sessionRole: session.role)
    c.delegateClass = ProbeDelegate.self
    return c
  }
}

final class ProbeDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  var field: UITextField?
  var keyboardHeight: Double = 0
  var hingeStatus: Int = -1
  var hingeAngle: Double = -1
  var busy = false
  var pending = false
  var cycle = 0

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions) {
    let window = UIWindow(windowScene: scene as! UIWindowScene)
    let controller = UIViewController()
    controller.view.backgroundColor = .systemTeal
    let field = UITextField(frame: CGRect(x: 40, y: 200, width: 200, height: 40))
    field.backgroundColor = .white
    controller.view.addSubview(field)
    let interaction = UIHingeInteraction { [weak self] _, update in
      guard let self else { return }
      if let hinge = update.hinge {
        self.hingeStatus = hinge.status.rawValue
        self.hingeAngle = Double(hinge.angle)
      } else { self.hingeStatus = -2 }
      print("DUOHINGE status=\(self.hingeStatus) angle=\(self.hingeAngle) bounds=\(UIScreen.main.bounds)")
      fflush(stdout)
      self.schedule()
    }
    controller.view.addInteraction(interaction)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window
    self.field = field
    for name in [UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidChangeFrameNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: name, object: nil)
    }
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.watchBounds() }
    schedule()
  }

  var lastBounds = CGRect.zero
  func watchBounds() {
    guard let w = window, !busy else { return }
    var b = w.windowScene?.screen.bounds ?? .zero
    b.origin.x = CGFloat(w.windowScene?.interfaceOrientation.rawValue ?? 0)
    if b != lastBounds { lastBounds = b; print("DUOBOUNDS \(b)"); fflush(stdout); schedule() }
  }

  func schedule() {
    if busy { pending = true; return }
    busy = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.measure() }
  }

  @objc func keyboardChanged(_ note: Notification) {
    guard let window = window, let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
    keyboardHeight = window.bounds.intersection(window.convert(end.cgRectValue, from: nil)).height
  }

  func insets(_ w: UIWindow) -> [String: Double] {
    let i = w.safeAreaInsets
    return ["left": i.left, "top": i.top, "right": i.right, "bottom": i.bottom]
  }

  func regions(_ w: UIWindow) -> [[String: Any]] {
    var out: [[String: Any]] = []
    let v = w.rootViewController!.view!
    for (name, kind) in [("division", UIView.ReservedRegion.Kind.division), ("occlusion", UIView.ReservedRegion.Kind.occlusion)] {
      for r in v.reservedRegions(kind: kind, options: .includeInactive) {
        out.append(["kind": name, "active": r.isActive,
          "frame": [r.frame.minX, r.frame.minY, r.frame.maxX, r.frame.maxY],
          "margins": [r.margins.left, r.margins.top, r.margins.right, r.margins.bottom]])
      }
    }
    return out
  }

  func snapshot() -> [String: Any] {
    let w = window!, scene = w.windowScene!, screen = scene.screen
    return [
      "window": ["width": w.bounds.width, "height": w.bounds.height],
      "screen": ["width": screen.bounds.width, "height": screen.bounds.height],
      "nativeBounds": ["width": screen.nativeBounds.width, "height": screen.nativeBounds.height],
      "scale": screen.scale,
      "cornerRadius": (screen.value(forKey: "_displayCornerRadius") as? Double) ?? 0,
      "orientation": scene.interfaceOrientation.rawValue,
      "padding": insets(w),
      "regions": regions(w),
      "keyboard": keyboardHeight, "keyboardPolls": 0, "rotateOK": 0,
    ]
  }

  func awaitKeyboard(_ polls: Int = 0, _ next: @escaping () -> Void) {
    if keyboardHeight > 0 || polls > 50 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { next() }; return }
    if polls % 10 == 0 { field?.becomeFirstResponder() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.awaitKeyboard(polls + 1, next) }
  }

  func rotate(_ mask: UIInterfaceOrientationMask, _ landscape: Bool, _ polls: Int = 0, _ next: @escaping () -> Void) {
    let w = window!, scene = w.windowScene!
    if polls == 0 { field?.resignFirstResponder(); keyboardHeight = 0
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) }
    if scene.interfaceOrientation.isLandscape == landscape || polls > 150 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }; return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.rotate(mask, landscape, polls + 1, next) }
  }

  func measure() {
    if ProcessInfo.processInfo.environment["PASSIVE"] != nil {
      cycle += 1
      keyboardHeight = 0
      field?.becomeFirstResponder()
      awaitKeyboard {
        var r: [String: Any] = ["cycle": self.cycle, "passive": true, "hingeStatus": self.hingeStatus, "hingeAngle": self.hingeAngle]
        r["current"] = self.snapshot()
        let data = try! JSONSerialization.data(withJSONObject: r)
        print("DUOPROBE " + String(data: data, encoding: .utf8)!); fflush(stdout)
        var lb = self.window?.windowScene?.screen.bounds ?? .zero
        lb.origin.x = CGFloat(self.window?.windowScene?.interfaceOrientation.rawValue ?? 0)
        self.lastBounds = lb
        self.busy = false
        if self.pending { self.pending = false; self.schedule() }
      }
      return
    }
    cycle += 1
    var result: [String: Any] = ["cycle": cycle, "hingeStatus": hingeStatus, "hingeAngle": hingeAngle]
    rotate(.portrait, false) {
      self.keyboardHeight = 0
      self.awaitKeyboard {
        result["portrait"] = self.snapshot()
        self.rotate(.landscapeRight, true) {
          self.awaitKeyboard {
            result["landscape"] = self.snapshot()
            self.rotate(.portrait, false) {
              result["hingeStatusAfter"] = self.hingeStatus
              let data = try! JSONSerialization.data(withJSONObject: result)
              print("DUOPROBE " + String(data: data, encoding: .utf8)!)
              fflush(stdout)
              self.lastBounds = self.window?.windowScene?.screen.bounds ?? .zero
              self.busy = false
              if self.pending { self.pending = false; self.schedule() }
            }
          }
        }
      }
    }
  }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
