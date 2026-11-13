import Flutter
import ObjectiveC
import UIKit

/// On iPadOS the scene can be resized while the app is backgrounded/locked
/// (Split View snapshot prep, flutter/flutter#128868). When that happens the
/// window bounds change in the system's own layout pass, but the engine only
/// re-creates its render surface from `viewDidLayoutSubviews` — and if the
/// view's frame was never re-set, the first frames after unlock are drawn
/// into a stale surface and the whole UI reads as stretched for a moment.
/// This swizzle forces the FlutterViewController's view to the window bounds
/// on EVERY layout pass, so the engine gets correct viewport metrics in the
/// same pass, before the frame is presented. Guarded to FlutterViewController
/// so no other view controller is affected.
extension UIViewController {
  @objc func dreamplayer_viewDidLayoutSubviews() {
    if self is FlutterViewController, let window = view.window,
       view.frame != window.bounds {
      SBMLog.log("viewDidLayoutSubviews: fixing flutter view \(view.frame.size) -> \(window.bounds.size)")
      view.frame = window.bounds
    }
    dreamplayer_viewDidLayoutSubviews()
  }

  static func installDreamplayerLayoutFix() {
    let original = class_getInstanceMethod(
      UIViewController.self, #selector(UIViewController.viewDidLayoutSubviews))
    let swizzled = class_getInstanceMethod(
      UIViewController.self, #selector(UIViewController.dreamplayer_viewDidLayoutSubviews))
    guard let original, let swizzled else { return }
    method_exchangeImplementations(original, swizzled)
  }
}

class SceneDelegate: FlutterSceneDelegate {

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    UIViewController.installDreamplayerLayoutFix()
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let url = connectionOptions.urlContexts.first?.url {
      IntentBridge.shared.setInitialURL(url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts {
      IntentBridge.shared.handleOpenURL(context.url)
    }
  }

  override func sceneWillEnterForeground(_ scene: UIScene) {
    super.sceneWillEnterForeground(scene)
    // Coming back from a real background/lock (not a quick app-switch):
    // cover the first frames with a soft-reload splash (app icon on black)
    // so a stale surface is never presented — the whole UI used to read
    // stretched for a moment here.
    if shouldShowUnlockSplash() {
      showUnlockSplash(scene)
    }
    wasInBackground = false
    backgroundedAt = nil
    // The scene may already carry its new size here (iPadOS resizes it while
    // the app is backgrounded), so relayout BEFORE the first foreground frame
    // is presented — otherwise that frame is drawn into a stale surface and
    // the whole UI reads as stretched for a moment.
    forceFlutterViewRelayout(scene)
    startRelayoutWatch(scene, for: 1.5)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    // Safety net: if willEnterForeground didn't run (or the splash wasn't
    // shown there), show it now, before the user sees a stretched frame.
    if shouldShowUnlockSplash() {
      showUnlockSplash(scene)
    }
    wasInBackground = false
    backgroundedAt = nil
    forceFlutterViewRelayout(scene)
    // iPadOS can resize the scene AFTER activation and the key window is not
    // always available yet, so a fixed set of delayed retries is not enough:
    // watch every frame for a few seconds and re-layout whenever the root
    // view's bounds no longer match the window's.
    startRelayoutWatch(scene, for: 3.0)
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    wasInBackground = true
    backgroundedAt = Date()
    // If a splash is somehow still up when we go back, drop it immediately.
    unlockSplash?.removeFromSuperview()
    unlockSplash = nil
    unlockSplashHideWork?.cancel()
    unlockSplashHideWork = nil
    relayoutWatch?.invalidate()
    relayoutWatch = nil
  }

  // MARK: - Unlock splash ("soft reload")

  /// Set in `sceneDidEnterBackground`, consumed on the next foreground pass
  /// so the splash only appears on a real background→foreground transition
  /// (lock/unlock) and never on cold launch or a quick app-switcher flip.
  private var wasInBackground = false
  private var backgroundedAt: Date?
  private var unlockSplash: UIView?
  private var unlockSplashHideWork: DispatchWorkItem?

  /// The stretch is an unlock symptom, so only show the splash when the app
  /// was actually away for a moment (≥ 2 s of wall-clock background). A quick
  /// app-switcher flip returns in well under that and stays snappy.
  private func shouldShowUnlockSplash() -> Bool {
    guard wasInBackground, let at = backgroundedAt else { return false }
    return Date().timeIntervalSince(at) >= 2.0
  }

  /// Full-screen overlay in the app's theme colour with the (currently
  /// selected) launcher icon centred. Added to the window itself so it sits
  /// above the Flutter view AND any platform-view video surface, hiding the
  /// stale frame. Non-interactive, so the player underneath keeps receiving
  /// its reload/resume calls.
  private func showUnlockSplash(_ scene: UIScene) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = windowScene.windows.first(where: { $0.isKeyWindow })
      ?? windowScene.windows.first(where: { !$0.isHidden })
      ?? windowScene.windows.first
    guard let window else { return }

    unlockSplash?.removeFromSuperview()
    unlockSplashHideWork?.cancel()

    // The app's theme colour instead of black, so the unlock reads as "the
    // app is coming back", not as a dead screen. This is the same pill colour
    // the NavigationBar paints behind the selected Library/Settings
    // destination — `ColorScheme.primaryContainer` of the current accent,
    // computed in Dart and persisted to SharedPreferences (Material 3 tone
    // mapping is not re-implemented here).
    let accent = Self.currentSplashColor()
    let splash = DreamPlayerGradientView(frame: window.bounds)
    splash.colors = [accent, accent.dreamplayerDarker(by: 0.72)]
    splash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    splash.isUserInteractionEnabled = false

    // Use the launcher icon the user currently has selected, so the splash
    // matches the home screen. Since 0.5.7 the PRIMARY icon is AppIconMark
    // (logo only), so a nil alternateIconName means the mark; the wordmark
    // variant is the "AppIcon" alternate.
    //
    // NOTE: the icon comes from a dedicated *imageset* (SplashIcon…), not
    // from the `.appiconset`. `UIImage(named:)` cannot load an app icon —
    // the asset compiler treats app icons specially and they are not in the
    // regular image namespace — so the old lookup returned nil and the
    // splash showed as a blank (black) rectangle with no icon at all.
    let iconName = UIApplication.shared.alternateIconName ?? "AppIconMark"
    let imageSet = Self.splashImageSet(for: iconName)
    let icon = UIImage(named: imageSet)
    let iconSize: CGFloat = 160
    if let icon {
      let imageView = UIImageView(image: icon)
      imageView.frame = CGRect(
        x: (window.bounds.width - iconSize) / 2,
        y: (window.bounds.height - iconSize) / 2,
        width: iconSize, height: iconSize)
      imageView.contentMode = .scaleAspectFit
      imageView.layer.cornerRadius = iconSize * 0.2237
      imageView.layer.masksToBounds = true
      imageView.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                                    .flexibleTopMargin, .flexibleBottomMargin]
      splash.addSubview(imageView)
    } else {
      // No icon is a packaging bug (missing imageset) — log it loudly
      // instead of silently showing a bare coloured screen.
      SBMLog.log("unlock splash: ICON MISSING (imageSet=\(imageSet))")
    }

    splash.alpha = 1.0
    window.addSubview(splash)
    unlockSplash = splash
    SBMLog.log("unlock splash: shown (icon=\(iconName) imageSet=\(imageSet) accent=\(accent.dreamplayerHex))")

    // The surface is re-created synchronously by forceFlutterViewRelayout
    // right after this; keep the splash up just long enough to read as a soft
    // reload (not a flash), then fade out. Capped so it can never stick.
    let work = DispatchWorkItem { [weak self] in self?.hideUnlockSplash() }
    unlockSplashHideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
  }

  private func hideUnlockSplash() {
    guard let splash = unlockSplash else { return }
    unlockSplash = nil
    unlockSplashHideWork = nil
    SBMLog.log("unlock splash: hiding")
    UIView.animate(withDuration: 0.25, animations: {
      splash.alpha = 0
    }, completion: { _ in
      splash.removeFromSuperview()
    })
  }

  // MARK: - Unlock splash theming

  /// Maps the selected launcher icon to the imageset that carries the same
  /// artwork as a *regular* asset (see the note in `showUnlockSplash`).
  static func splashImageSet(for iconName: String) -> String {
    switch iconName {
    case "AppIconMark": return "SplashIconMark"
    case "AppIconRed": return "SplashIconRed"
    case "AppIconGreen": return "SplashIconGreen"
    case "AppIconCyan": return "SplashIconCyan"
    case "AppIcon": return "SplashIcon"
    default: return "SplashIconMark"
    }
  }

  /// The accent the user picked in Settings → Appearance, mirroring
  /// `lib/services/accent_store.dart`. SharedPreferences prefixes its keys
  /// with `flutter.` on iOS, so the native side reads
  /// `flutter.dreamplayer.accent` straight from UserDefaults.
  static func currentAccentColor() -> UIColor {
    let id = UserDefaults.standard.string(forKey: "flutter.dreamplayer.accent")
    return accentColor(for: id)
  }

  /// The splash colour: the NavigationBar indicator colour of the current
  /// accent (`ColorScheme.primaryContainer`), written by Dart as `0xAARRGGBB`
  /// under `flutter.dreamplayer.accentIndicator`. Falls back to the raw
  /// accent mirror when the pref is missing (e.g. a build that predates it).
  static func currentSplashColor() -> UIColor {
    if let hex = UserDefaults.standard.string(forKey: "flutter.dreamplayer.accentIndicator"),
       let color = color(fromHex: hex) {
      return color
    }
    return currentAccentColor()
  }

  /// Parses `0xAARRGGBB` / `AARRGGBB` / `RRGGBB` (alpha defaults to FF).
  static func color(fromHex hex: String) -> UIColor? {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.lowercased().hasPrefix("0x") { s.removeFirst(2) }
    if s.count == 6 { s = "FF" + s }
    guard s.count == 8 else { return nil }
    var value: UInt64 = 0
    guard Scanner(string: s).scanHexInt64(&value) else { return nil }
    // 255.0 on purpose: / 255 would be integer division and yield 0 (black).
    let a = CGFloat((value >> 24) & 0xFF) / 255.0
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }

  /// Accent palette, kept in step with `AccentStore.accents`.
  /// NOTE: the divisor is `255.0` (a floating-point literal) on purpose —
  /// `0x7C / 255` is INTEGER division in Swift and would be 0 (black).
  static func accentColor(for id: String?) -> UIColor {
    switch id {
    case "blue": return UIColor(red: 0x3D / 255.0, green: 0x7B / 255.0, blue: 0xFF / 255.0, alpha: 1)
    case "cyan": return UIColor(red: 0x00 / 255.0, green: 0xB5 / 255.0, blue: 0xD8 / 255.0, alpha: 1)
    case "green": return UIColor(red: 0x2F / 255.0, green: 0xBF / 255.0, blue: 0x71 / 255.0, alpha: 1)
    case "amber": return UIColor(red: 0xFF / 255.0, green: 0xA7 / 255.0, blue: 0x26 / 255.0, alpha: 1)
    case "pink": return UIColor(red: 0xFF / 255.0, green: 0x4D / 255.0, blue: 0x8D / 255.0, alpha: 1)
    default: return UIColor(red: 0x7C / 255.0, green: 0x4D / 255.0, blue: 0xFF / 255.0, alpha: 1)
    }
  }

  // MARK: - Relayout watch

  private var relayoutWatch: CADisplayLink?
  private var relayoutWatchEnd: CFTimeInterval = 0
  private weak var relayoutWatchScene: UIScene?

  /// Runs [relayoutTick] on every frame for [seconds] after foregrounding, so
  /// a late scene resize (Split View snapshot prep, flutter/flutter#128868)
  /// is picked up on the very next frame instead of waiting for an unrelated
  /// layout pass.
  private func startRelayoutWatch(_ scene: UIScene, for seconds: CFTimeInterval) {
    guard scene is UIWindowScene else { return }
    relayoutWatch?.invalidate()
    relayoutWatchScene = scene
    relayoutWatchEnd = CACurrentMediaTime() + seconds
    let link = CADisplayLink(target: self, selector: #selector(relayoutTick(_:)))
    link.add(to: .main, forMode: .common)
    relayoutWatch = link
  }

  @objc private func relayoutTick(_ link: CADisplayLink) {
    guard let scene = relayoutWatchScene as? UIWindowScene else {
      link.invalidate(); relayoutWatch = nil; return
    }
    if CACurrentMediaTime() > relayoutWatchEnd {
      link.invalidate(); relayoutWatch = nil; return
    }
    for window in scene.windows where !window.isHidden {
      guard let rootView = window.rootViewController?.viewIfLoaded else { continue }
      let target = window.bounds
      if target.width <= 0 || target.height <= 0 { continue }
      if rootView.bounds.width != target.width || rootView.bounds.height != target.height {
        SBMLog.log("relayout watch: root \(rootView.bounds.size) != window \(target.size) — forcing")
        rootView.frame = target
        rootView.setNeedsLayout()
        rootView.layoutIfNeeded()
        // Nudge once more so viewDidLayoutSubviews runs even when the engine
        // cached the previous bounds.
        rootView.frame = CGRect(x: target.minX + 0.5, y: target.minY,
                                width: target.width - 0.5, height: target.height)
        rootView.setNeedsLayout()
        rootView.layoutIfNeeded()
        rootView.frame = target
        rootView.setNeedsLayout()
        rootView.layoutIfNeeded()
      }
    }
  }

  /// Flutter only re-sizes its on-screen render surface when the
  /// `FlutterViewController` view is laid out again with changed bounds.
  /// iPadOS resizes the scene while the app is backgrounded/locked (Split View
  /// snapshot prep, flutter/flutter#128868), so on unlock the engine can keep
  /// presenting a stale surface at the wrong size — the whole UI (library,
  /// Jellyfin/WebDAV lists, settings) renders stretched / aspect-mismatched
  /// until some unrelated later layout pass happens to re-measure it.
  /// Force a synchronous re-layout on foreground, nudging the frame so the
  /// bounds genuinely change twice; `viewDidLayoutSubviews` then runs and the
  /// engine re-creates the surface at the current window size immediately.
  private func forceFlutterViewRelayout(_ scene: UIScene) {
    guard scene.activationState == .foregroundActive
        || scene.activationState == .foregroundInactive,
      let windowScene = scene as? UIWindowScene
    else { return }

    let window = windowScene.windows.first(where: { $0.isKeyWindow })
      ?? windowScene.windows.first(where: { !$0.isHidden })
      ?? windowScene.windows.first
    // Use `.view` (forces load) rather than `viewIfLoaded`: at
    // sceneWillEnterForeground the root view is often not loaded yet, and
    // skipping it would let the first foreground frame draw into a stale
    // surface.
    guard let window, let rootView = window.rootViewController?.view else { return }

    let target = window.bounds
    guard target.width > 0, target.height > 0 else { return }

    SBMLog.log("forceFlutterViewRelayout: window \(target.size), root \(rootView.bounds.size)")
    rootView.frame = CGRect(x: target.minX + 0.5, y: target.minY, width: target.width - 0.5, height: target.height)
    rootView.setNeedsLayout()
    rootView.layoutIfNeeded()

    rootView.frame = target
    rootView.setNeedsLayout()
    rootView.layoutIfNeeded()
  }
}

/// A view whose background is a vertical two-colour gradient. Used by the
/// unlock splash: the app's accent colour at the top fading to a darker
/// shade of the same hue at the bottom, so the screen reads as branded
/// instead of a flat black rectangle.
///
/// The gradient layer is resized in `layoutSubviews` — the splash is added
/// straight to the window and the window can be resized (rotation, Split
/// View) while it is up.
final class DreamPlayerGradientView: UIView {

  var colors: [UIColor] = [] {
    didSet { updateGradient() }
  }

  private let gradient = CAGradientLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    gradient.startPoint = CGPoint(x: 0.5, y: 0)
    gradient.endPoint = CGPoint(x: 0.5, y: 1)
    layer.insertSublayer(gradient, at: 0)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    gradient.startPoint = CGPoint(x: 0.5, y: 0)
    gradient.endPoint = CGPoint(x: 0.5, y: 1)
    layer.insertSublayer(gradient, at: 0)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    gradient.frame = bounds
  }

  private func updateGradient() {
    gradient.colors = colors.map(\.cgColor)
    gradient.frame = bounds
  }
}

extension UIColor {
  /// Multiplies the RGB components by [factor] (alpha untouched) — used to
  /// derive the darker end of the splash gradient from the accent colour.
  func dreamplayerDarker(by factor: CGFloat) -> UIColor {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
    return UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
  }

  /// `#RRGGBB` — logged so the device log says which accent was used.
  var dreamplayerHex: String {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
    return String(format: "#%02X%02X%02X",
                  Int((r * 255).rounded()),
                  Int((g * 255).rounded()),
                  Int((b * 255).rounded()))
  }
}
