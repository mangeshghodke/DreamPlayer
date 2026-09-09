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

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    forceFlutterViewRelayout(scene)
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
    guard scene.activationState == .foregroundActive,
      let windowScene = scene as? UIWindowScene,
      let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
      let rootView = window.rootViewController?.viewIfLoaded
    else { return }

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
