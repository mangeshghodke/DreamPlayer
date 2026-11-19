import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Google Cast session state.
enum CastState {
  /// Cast is not available on this device (no Cast hardware on the LAN).
  notAvailable,
  /// Cast is available but no session is active.
  notConnected,
  /// Connecting to a Cast device.
  connecting,
  /// Connected to a Cast device; media can be loaded.
  connected,
}

/// A Cast device the user can cast to.
class CastDevice {
  const CastDevice({
    required this.deviceId,
    required this.friendlyName,
  });

  final String deviceId;
  final String friendlyName;
}

/// Google Cast integration (iOS only).
///
/// Wraps Google's `GCKCastContext` / `GCKCastButton` / `GCKCastSession` over a
/// MethodChannel (`dreamplayer/cast`). Cast sends the media URL to a receiver
/// that decodes it natively, so only sources the receiver can reach are
/// castable: `http`/`https` URLs (non-loopback), `content://` and `file://`.
/// Loopback proxies (127.0.0.1 / localhost) and the MPV loopback bridge are
/// explicitly excluded - the Cast device cannot reach the phone's loopback.
///
/// On iOS this is backed by the Google Cast SDK (`google-cast-sdk` CocoaPod).
/// Android is not cast-capable in this build.
class CastManager extends ChangeNotifier {
  CastManager._();

  static final CastManager instance = CastManager._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/cast');
  static const EventChannel _events =
      EventChannel('dreamplayer/cast/events');

  CastState _state = CastState.notAvailable;
  CastDevice? _device;
  bool _casting = false;

  CastState get state => _state;
  CastDevice? get device => _device;
  /// True while a Cast session is active and the video plays on the receiver.
  bool get casting => _casting;
  /// True when Cast is available (a Cast device was discovered on the LAN).
  bool get available => _state != CastState.notAvailable;

  StreamSubscription<dynamic>? _sub;

  /// Loads the Cast context and starts device discovery. iOS-only; Android /
  /// desktop / web answer `false` immediately.
  Future<bool> init() async {
    if (!Platform.isIOS || kIsWeb) {
      _state = CastState.notAvailable;
      notifyListeners();
      return false;
    }
    try {
      final available = await _channel.invokeMethod<bool>('castInit') ?? false;
      _state = available ? CastState.notConnected : CastState.notAvailable;
      _sub?.cancel();
      _sub = _events.receiveBroadcastStream().listen(
        (event) {
          final map = event as Map<dynamic, dynamic>;
          final kind = map['kind'] as String?;
          switch (kind) {
            case 'sessionStateChanged':
              _onSessionState(map);
            case 'deviceNameChanged':
              _device = map['deviceId'] != null && map['friendlyName'] != null
                  ? CastDevice(
                      deviceId: map['deviceId'] as String,
                      friendlyName: map['friendlyName'] as String,
                    )
                  : null;
              notifyListeners();
            case 'sessionEnded':
              _endSession();
              notifyListeners();
            default:
              break;
          }
        },
        onError: (_) {},
      );
      notifyListeners();
      return available;
    } catch (_) {
      _state = CastState.notAvailable;
      notifyListeners();
      return false;
    }
  }

  void _onSessionState(Map<dynamic, dynamic> map) {
    final state = map['state'] as String?;
    switch (state) {
      case 'connecting':
        _state = CastState.connecting;
        break;
      case 'connected':
        _state = CastState.connected;
        _casting = true;
        break;
      case 'notConnected':
        _endSession();
        break;
      default:
        break;
    }
    notifyListeners();
  }

  void _endSession() {
    _state = CastState.notConnected;
    _casting = false;
    _device = null;
  }

  /// Starts a Cast session and lets the user pick a device (shows the Cast
  /// dialog). Returns the chosen device, or null if the user cancelled.
  Future<CastDevice?> startSession() async {
    if (!Platform.isIOS || _state == CastState.notAvailable) return null;
    try {
      final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'castStartSession',
      );
      if (map == null) return null;
      _device = CastDevice(
        deviceId: map['deviceId'] as String,
        friendlyName: map['friendlyName'] as String,
      );
      _state = CastState.connected;
      _casting = true;
      notifyListeners();
      return _device;
    } catch (_) {
      return null;
    }
  }

  /// Ends the Cast session and returns playback to the phone.
  Future<void> endSession() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('castEndSession');
    } catch (_) {}
    _endSession();
    notifyListeners();
  }

  /// Loads [url] onto the Cast receiver. Returns true if the load was
  /// accepted. Only call this once a session is connected.
  Future<bool> loadMedia({
    required String url,
    required String title,
    required String subtitle,
    required String streamType, // 'NONE', 'BUFFERED', 'LIVE'
    required int durationMs,
    required String contentType, // MIME type, e.g. 'video/mp4'
  }) async {
    if (!Platform.isIOS || _state != CastState.connected) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('castLoadMedia', {
        'url': url,
        'title': title,
        'subtitle': subtitle,
        'streamType': streamType,
        'durationMs': durationMs,
        'contentType': contentType,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Pauses playback on the Cast receiver.
  Future<void> pause() async {
    if (!Platform.isIOS || _state != CastState.connected) return;
    try {
      await _channel.invokeMethod('castPause');
    } catch (_) {}
  }

  /// Resumes playback on the Cast receiver.
  Future<void> play() async {
    if (!Platform.isIOS || _state != CastState.connected) return;
    try {
      await _channel.invokeMethod('castPlay');
    } catch (_) {}
  }

  /// Seeks playback on the Cast receiver to [positionMs].
  Future<void> seek(int positionMs) async {
    if (!Platform.isIOS || _state != CastState.connected) return;
    try {
      await _channel.invokeMethod('castSeek', {'positionMs': positionMs});
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}

/// Castable-source decision. Pure: the receiver can only reach sources it can
/// fetch over the LAN/internet, so loopback proxies and local phone files are
/// excluded.
class CastSource {
  CastSource._();

  /// True when [url] can be handed to a Cast receiver for native playback.
  ///
  /// Castable:
  ///   - `http`/`https` URLs (excluding `127.0.0.1`/`localhost` loopback)
  ///   - `content://` URIs (Android content providers - not iOS)
  ///   - `file://` absolute paths (only if the receiver shares the FS; rare)
  ///
  /// Not castable:
  ///   - Loopback HTTP(S) (SmbHttpProxy bound to 127.0.0.1, MPV loopback
  ///     bridge, CX Explorer proxy) - the receiver cannot reach the phone's
  ///     loopback.
  ///   - `smb://`, `ftp://`, `dreamplayersmb://` etc. - custom schemes the
  ///     receiver doesn't understand.
  static bool isCastable(String? url) {
    if (url == null || url.isEmpty) return false;
    try {
      final uri = Uri.parse(url);
      switch (uri.scheme) {
        case 'http':
        case 'https':
          final host = uri.host.toLowerCase();
          return host != '127.0.0.1' &&
              host != 'localhost' &&
              !host.startsWith('127.') &&
              !host.startsWith('0.0.0.0');
        case 'content':
        case 'file':
          return true;
        default:
          return false;
      }
    } catch (_) {
      return false;
    }
  }

  /// Human reason why [url] cannot be cast, or null when it can.
  static String? notCastableReason(String? url) {
    if (url == null || url.isEmpty) return 'No media URL';
    try {
      final uri = Uri.parse(url);
      switch (uri.scheme) {
        case 'http':
        case 'https':
          final host = uri.host.toLowerCase();
          if (host == '127.0.0.1' ||
              host == 'localhost' ||
              host.startsWith('127.') ||
              host.startsWith('0.0.0.0')) {
            return 'Loopback streams cannot be cast';
          }
          return null;
        case 'content':
        case 'file':
          return null;
        default:
          return 'Not a castable source';
      }
    } catch (_) {
      return 'Invalid media URL';
    }
  }
}
