import Flutter
import UIKit
import Network

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  /// iOS has no API to request Local Network permission on demand — the
  /// dialog appears once, triggered by the first local-network access.
  /// Browsing any Bonjour service deterministically triggers that evaluation,
  /// so we fire it as soon as the app is active instead of mid-flow (e.g.
  /// while the user is already tapping an FTP "Test" button). The probe finds
  /// nothing by design; it exists only to make iOS show the prompt early.
  private var lnProbeBrowser: NWBrowser?

  private func triggerLocalNetworkPrompt() {
    guard lnProbeBrowser == nil else { return }
    let params = NWParameters()
    params.includePeerToPeer = true
    let browser = NWBrowser(
      for: .bonjour(type: "_dreamplayer-probe._tcp.", domain: "local."),
      using: params)
    browser.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready, .failed, .cancelled:
        self?.lnProbeBrowser?.cancel()
        self?.lnProbeBrowser = nil
      default:
        break
      }
    }
    browser.start(queue: .main)
    lnProbeBrowser = browser
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    triggerLocalNetworkPrompt()
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let url = launchOptions?[.url] as? URL {
      IntentBridge.shared.setInitialURL(url)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    IntentBridge.shared.handleOpenURL(url)
    return true
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DreamPlayer") else {
      return
    }
    let messenger = registrar.messenger()
    registrar.register(
      AvPlayerViewFactory(messenger: messenger),
      withId: "dreamplayer/exo_player"
    )
    FileBrowser.register(with: messenger)
    IntentBridge.shared.configure(with: messenger)
    WebDAVClient.register(with: messenger)
    FtpClient.register(with: messenger)
    JellyfinDiscovery.register(with: messenger)
    CacheCleaner.register(with: messenger)
    UpnpClient.register(with: messenger)
    MediaProbe.register(with: messenger)
  }
}
