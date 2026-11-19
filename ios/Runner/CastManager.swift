import Flutter
import GoogleCast

/// Google Cast manager (iOS only).
///
/// Wraps `GCKCastContext` / `GCKSessionManager` / `GCKCastSession` and exposes
/// them over the `dreamplayer/cast` MethodChannel / `dreamplayer/cast/events`
/// EventChannel so Dart can start a session, load media and read the session
/// state.
///
/// Uses the modern v4 sender API: session lifecycle events arrive via
/// `GCKSessionManagerListener` (registered on `context.sessionManager`), NOT
/// the deprecated v2 `GCKCastDelegate` castContext callbacks.
///
/// Only sources the Cast receiver can reach are castable: `http`/`https`
/// (non-loopback), `content://` and `file://`. Loopback proxies (127.0.0.1)
/// and custom schemes (`smb://`, `dreamplayersmb://`) are rejected on the Dart
/// side before this is ever called.
///
/// Registration: `CastManager.register(with: messenger)` from `AppDelegate`.
/// The Cast button platform view (`CastButtonFactory`, view id
/// `dreamplayer/cast_button`) is registered alongside it.
final class CastManager: NSObject, FlutterStreamHandler,
    GCKSessionManagerListener, GCKRemoteMediaClientListener {

  static let channelName = "dreamplayer/cast"
  static let eventsChannelName = "dreamplayer/cast/events"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger)
    let events = FlutterEventChannel(
      name: eventsChannelName,
      binaryMessenger: messenger)
    let manager = CastManager()
    channel.setMethodCallHandler(manager.handle(call:result:))
    events.setStreamHandler(manager)
  }

  // MARK: - State

  private var context: GCKCastContext?
  private var eventSink: FlutterEventSink?

  /// The current Cast session, if any.
  private var session: GCKCastSession? {
    context?.sessionManager.currentCastSession
  }

  private var _state: String = "notAvailable" {
    didSet { sendEvent(state: _state) }
  }
  private var _deviceId: String? {
    didSet { sendEvent(state: _state, deviceId: _deviceId, friendlyName: _deviceName) }
  }
  private var _deviceName: String? {
    didSet { sendEvent(state: _state, deviceId: _deviceId, friendlyName: _deviceName) }
  }

  private func sendEvent(state: String? = nil, deviceId: String? = nil,
                         friendlyName: String? = nil) {
    let s = state ?? _state
    let d = deviceId ?? _deviceId
    let n = friendlyName ?? _deviceName
    let event: [String: Any?] = [
      "kind": "sessionStateChanged",
      "state": s,
      "deviceId": d as Any,
      "friendlyName": n as Any,
    ]
    eventSink?(event)
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?,
                eventSink: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = eventSink
    sendEvent(state: _state, deviceId: _deviceId, friendlyName: _deviceName)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: - MethodChannel

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "castInit":
      result(initializeCast())
    case "castStartSession":
      startSession(result: result)
    case "castEndSession":
      endSession(result: result)
    case "castLoadMedia":
      loadMedia(call: call, result: result)
    case "castPause":
      pause(result: result)
    case "castPlay":
      play(result: result)
    case "castSeek":
      seek(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Initialization

  @discardableResult
  private func initializeCast() -> Bool {
    // Guard against double-initialization: setSharedInstanceWith throws if
    // the shared instance already exists (e.g. a hot restart re-enters this).
    if GCKCastContext.isSharedInstanceInitialized {
      context = GCKCastContext.sharedInstance()
    } else {
      let criteria = GCKDiscoveryCriteria(
        applicationID: kGCKDefaultMediaReceiverApplicationID)
      let options = GCKCastOptions(discoveryCriteria: criteria)
      GCKCastContext.setSharedInstanceWith(options)
      context = GCKCastContext.sharedInstance()
    }
    // Session lifecycle events come through GCKSessionManagerListener.
    context?.sessionManager.add(self)
    // Cast-state changes (device discovered / lost) come via this notification;
    // discovery is asynchronous so the initial deviceCount is usually 0.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(castStateChanged),
      name: NSNotification.Name(kGCKCastStateDidChangeNotification),
      object: context)

    updateAvailability()
    return context?.castState != .noDevicesAvailable
  }

  @objc private func castStateChanged() {
    updateAvailability()
  }

  private func updateAvailability() {
    guard let context = context else { return }
    // Only downgrade to notAvailable when there is genuinely no device AND no
    // active session - a connected session must never be reported as
    // "not available" just because discovery is momentarily empty.
    if context.castState == .noDevicesAvailable && session == nil {
      _state = "notAvailable"
    } else if session == nil && _state != "connected" {
      _state = "notConnected"
    }
    sendEvent(state: _state)
  }

  // MARK: - Session

  private func startSession(result: @escaping FlutterResult) {
    guard context != nil else {
      result(FlutterError(code: "not_initialized",
                          message: "Cast context not initialized", details: nil))
      return
    }
    // `presentCastInstructionsViewControllerOnce` shows the device picker the
    // first time it is invoked; the native `GCKCastButton` handles the picker
    // on subsequent taps. Session state arrives via GCKSessionManagerListener.
    context?.presentCastInstructionsViewControllerOnce()
    result(nil)
  }

  private func endSession(result: @escaping FlutterResult) {
    context?.sessionManager.endSession()
    result(nil)
  }

  // MARK: - Media

  private func loadMedia(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let urlString = args["url"] as? String,
          let url = URL(string: urlString) else {
      result(FlutterError(code: "bad_args", message: "url is required", details: nil))
      return
    }
    guard let session = session else {
      result(FlutterError(code: "no_session",
                          message: "No Cast session", details: nil))
      return
    }
    // GCKMediaInformationBuilder is the non-deprecated path (the raw
    // GCKMediaInformation initializer is deprecated since 4.3). contentURL is
    // the required attribute; contentID alone is deprecated.
    let builder = GCKMediaInformationBuilder(contentURL: url)
    builder.contentType = args["contentType"] as? String ?? "video/mp4"
    builder.streamType = GCKMediaStreamType(rawValue: args["streamType"] as? Int ?? 1)
      ?? .buffered
    let durationMs = args["durationMs"] as? Int ?? 0
    if durationMs > 0 {
      builder.streamDuration = TimeInterval(durationMs) / 1000.0
    }
    let metadata = GCKMediaMetadata(metadataType: .movie)
    metadata.setString(args["title"] as? String, forKey: kGCKMetadataKeyTitle)
    metadata.setString(args["subtitle"] as? String, forKey: kGCKMetadataKeySubtitle)
    builder.metadata = metadata
    let info = builder.build()
    session.remoteMediaClient.load(
      info,
      autoplay: true,
      playPosition: 0)
    result(true)
  }

  private func pause(result: @escaping FlutterResult) {
    session?.remoteMediaClient.pause()
    result(nil)
  }

  private func play(result: @escaping FlutterResult) {
    session?.remoteMediaClient.play()
    result(nil)
  }

  private func seek(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let positionMs = args["positionMs"] as? Int else {
      result(FlutterError(code: "bad_args", message: "positionMs is required", details: nil))
      return
    }
    session?.remoteMediaClient.seek(
      toTimeInterval: TimeInterval(positionMs) / 1000.0)
    result(nil)
  }

  // MARK: - GCKSessionManagerListener

  func sessionManager(_ sessionManager: GCKSessionManager,
                      didStart session: GCKCastSession) {
    _deviceId = session.castDevice.deviceId
    _deviceName = session.castDevice.friendlyName
    _state = "connected"
    session.remoteMediaClient.add(self)
    sendEvent(state: _state, deviceId: _deviceId, friendlyName: _deviceName)
  }

  func sessionManager(_ sessionManager: GCKSessionManager,
                      didResumeCastSession session: GCKCastSession) {
    _deviceId = session.castDevice.deviceId
    _deviceName = session.castDevice.friendlyName
    _state = "connected"
    session.remoteMediaClient.add(self)
    sendEvent(state: _state, deviceId: _deviceId, friendlyName: _deviceName)
  }

  func sessionManager(_ sessionManager: GCKSessionManager,
                      didEnd session: GCKSession,
                      withError error: Error?) {
    _endSession()
  }

  func sessionManager(_ sessionManager: GCKSessionManager,
                      didSuspend session: GCKCastSession,
                      with reason: GCKConnectionSuspendReason) {
    // App went to background; session may resume later. Keep the flag but
    // report notConnected so Dart pauses its local UI.
    _endSession()
  }

  // MARK: - GCKRemoteMediaClientListener

  func remoteMediaClient(_ client: GCKRemoteMediaClient,
                         didUpdate mediaStatus: GCKMediaStatus?) {
    // Playback state changes on the receiver. The receiver owns playback;
    // nothing to sync back to Dart for now.
  }

  // MARK: - Private

  private func _endSession() {
    _state = "notConnected"
    _deviceId = nil
    _deviceName = nil
    sendEvent(state: _state)
  }
}
