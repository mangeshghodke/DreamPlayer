import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
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
    // The scene may already carry its new size here (iPadOS resizes it while
    // the app is backgrounded), so relayout BEFORE the first foreground frame
    // is presented — otherwise that frame is drawn into a stale surface and
    // the whole UI reads as stretched for a moment.
    forceFlutterViewRelayout(scene)
    startRelayoutWatch(scene, for: 1.5)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    forceFlutterViewRelayout(scene)
    // iPadOS can resize the scene AFTER activation and the key window is not
    // always available yet, so a fixed set of delayed retries is not enough:
    // watch every frame for a few seconds and re-layout whenever the root
    // view's bounds no longer match the window's.
    startRelayoutWatch(scene, for: 3.0)
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    relayoutWatch?.invalidate()
    relayoutWatch = nil
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
    guard let window, let rootView = window.rootViewController?.viewIfLoaded else { return }

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
