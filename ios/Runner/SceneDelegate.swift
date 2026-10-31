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
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    forceFlutterViewRelayout(scene)
    // Two things can still be wrong at activation time: iPadOS can resize the
    // scene AFTER this callback, and the key window is not always available
    // yet (the relayout above then finds no window and does nothing). Re-run
    // it a few times over the next fraction of a second so a late resize — or
    // a window that only appears now — is picked up.
    for delay in [0.05, 0.2, 0.5] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.forceFlutterViewRelayout(scene)
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

    rootView.frame = CGRect(x: target.minX + 0.5, y: target.minY, width: target.width - 0.5, height: target.height)
    rootView.setNeedsLayout()
    rootView.layoutIfNeeded()

    rootView.frame = target
    rootView.setNeedsLayout()
    rootView.layoutIfNeeded()
  }
}
