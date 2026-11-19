import Flutter
import GoogleCast

/// Google Cast manager (iOS only).
///
/// Wraps `GCKCastContext`, `GCKCastButton` and `GCKCastSession` and exposes
/// them over the `dreamplayer/cast` MethodChannel / `dreamplayer/cast/events`
/// EventChannel so Dart can start a session, load media and read the session
/// state.
///
/// Only sources the Cast receiver can reach are castable: `http`/`https`
/// (non-loopback), `content://` and `file://`. Loopback proxies (127.0.0.1)
/// and custom schemes (`smb://`, `dreamplayersmb://`) are rejected on the Dart
/// side before this is ever called.
///
/// Registration: `CastManager.register(with: messenger)` from `AppDelegate`.
/// The Cast button platform view (`CastButtonFactory`, view id
/// `dreamplayer/cast_button`) is registered alongside it.
final class CastManager: NSObject, FlutterStreamHandler, GCKCastDelegate,
    GCKRemoteMediaClientListener {

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
  private var session: GCKCastSession? {
    context?.currentSession
  }
  private var eventSink: FlutterEventSink?

  private var _state: String = "notAvailable" {
    didSet { sendEvent(state: _state) }
  }
  private var _deviceId: String? {
    didSet { sendDeviceEvent(deviceId: _deviceId, friendlyName: _deviceName) }
  }
  private var _deviceName: String? {
    didSet { sendDeviceEvent(deviceId: _deviceId, friendlyName: _deviceName) }
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

  private func sendDeviceEvent(deviceId: String?, friendlyName: String?) {
    let event: [String: Any?] = [
      "kind": "sessionStateChanged",
      "state": _state,
      "deviceId": deviceId as Any,
      "friendlyName": friendlyName as Any,
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
    let criteria = GCKDiscoveryCriteria(
      applicationID: kGCKDefaultMediaReceiverApplicationID)
    let options = GCKCastOptions(discoveryCriteria: criteria)
    options.physicalConnectionType = .none
    GCKCastContext.setSharedInstanceWith(options)
    context = GCKCastContext.sharedInstance()
    context?.castDelegate = self

    let available = context?.discoveryManager.deviceCount ?? 0 > 0
    _state = available ? "notConnected" : "notAvailable"
    sendEvent(state: _state)
    return available
  }

  // MARK: - Session

  private func startSession(result: @escaping FlutterResult) {
    guard context != nil else {
      result(FlutterError(code: "not_initialized",
                          message: "Cast context not initialized", details: nil))
      return
    }
    // `presentCastInstructionsViewControllerOnce` shows the device picker
    // the first time it is invoked; the native `GCKCastButton` handles the
    // picker on subsequent taps. Session state arrives via castDelegate.
    context?.presentCastInstructionsViewControllerOnce()
    result(nil)
  }

  private func endSession(result: @escaping FlutterResult) {
    context?.currentSession?.end()
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
    guard let session = context?.currentSession else {
      result(FlutterError(code: "no_session",
                          message: "No Cast session", details: nil))
      return
    }
    let metadata = GCKMediaMetadata()
    metadata.setString(args["title"] as? String, forKey: kGCKMetadataKeyTitle)
    metadata.setString(args["subtitle"] as? String, forKey: kGCKMetadataKeySubtitle)
    let info = GCKMediaInformation(
      contentID: urlString,
      contentType: args["contentType"] as? String ?? "video/mp4",
      streamType: GCKMediaStreamType(rawValue: args["streamType"] as? Int ?? 0)
        ?? .none,
      duration: TimeInterval(args["durationMs"] as? Int ?? 0),
      metadata: metadata,
      textTracks: nil,
      textTrackStyle: nil,
      customData: nil)
    session.remoteMediaClient.load(
      info,
      autoplay: true,
      playPosition: 0)
    result(true)
  }

  private func pause(result: @escaping FlutterResult) {
    context?.currentSession?.remoteMediaClient.pause()
    result(nil)
  }

  private func play(result: @escaping FlutterResult) {
    context?.currentSession?.remoteMediaClient.play()
    result(nil)
  }

  private func seek(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let positionMs = args["positionMs"] as? Int else {
      result(FlutterError(code: "bad_args", message: "positionMs is required", details: nil))
      return
    }
    context?.currentSession?.remoteMediaClient.seek(
      toTimeInterval: TimeInterval(positionMs) / 1000.0)
    result(nil)
  }

  // MARK: - GCKCastDelegate

  func castContextDidChange(_ castContext: GCKCastContext) {
    updateState()
  }

  func castContext(_ castContext: GCKCastContext,
                   didStart session: GCKCastSession,
                   with castDevice: GCKCastDevice) {
    _deviceId = castDevice.deviceId
    _deviceName = castDevice.friendlyName
    _state = "connected"
    session.castDelegate = self
    session.remoteMediaClient.add(self)
    sendEvent(state: _state, deviceId: _deviceId, friendlyName: _deviceName)
  }

  func castContext(_ castContext: GCKCastContext,
                   didStop session: GCKCastSession,
                   with castDevice: GCKCastDevice,
                   error: Error?) {
    if _deviceId == castDevice.deviceId {
      _endSession()
    }
  }

  // MARK: - GCKRemoteMediaClientListener

  func remoteMediaClient(_ client: GCKRemoteMediaClient,
                         didUpdate mediaStatus: GCKMediaStatus?) {
    // Playback state changes on the receiver. The receiver owns playback;
    // nothing to sync back to Dart for now.
  }

  // MARK: - Private

  private func updateState() {
    guard let context = context else { return }
    let available = context.discoveryManager.deviceCount > 0
    _state = available ? "notConnected" : "notAvailable"
    if _state == "notAvailable" {
      _deviceId = nil
      _deviceName = nil
    }
    sendEvent(state: _state)
  }

  private func _endSession() {
    _state = "notConnected"
    _deviceId = nil
    _deviceName = nil
    sendEvent(state: _state)
  }
}
