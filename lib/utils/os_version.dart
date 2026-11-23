import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _deviceChannel = MethodChannel('dreamplayer/device');

int? _cachedOsMajor;

/// OS major version via the `dreamplayer/device` channel (Android: SDK int,
/// iOS: `UIDevice.systemVersion` major). Cached after the first call; null when
/// the channel is unavailable.
Future<int?> osMajorVersion() async {
  if (_cachedOsMajor != null) return _cachedOsMajor;
  if (defaultTargetPlatform != TargetPlatform.android &&
      defaultTargetPlatform != TargetPlatform.iOS) {
    return null;
  }
  try {
    final v = await _deviceChannel.invokeMethod<int>('osMajorVersion');
    _cachedOsMajor = v;
    return v;
  } catch (_) {
    return null;
  }
}

/// True when the device runs iOS 26+ - the floor of the AetherEngine MetalFX
/// upscale stage (`#available(iOS 26, ...)` in the engine), so the Settings
/// toggle is only offered where it can actually do something.
Future<bool> isIos26OrLater() async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return false;
  final major = await osMajorVersion();
  return major != null && major >= 26;
}

String? _cachedWebViewUa;

/// The installed Android WebView's real User-Agent, via the
/// `dreamplayer/device` channel. Used as the default `User-Agent` for the
/// mpv engine's http requests - a device-browser UA is accepted by CDNs that
/// blocklist ffmpeg's `Lavf/…` (and by ones that check the UA version).
/// Cached after the first call; null when unavailable (non-Android, or the
/// channel answer failed) - callers fall back to [mpvBrowserUserAgent].
Future<String?> webViewUserAgent() async {
  if (_cachedWebViewUa != null) return _cachedWebViewUa;
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final ua = await _deviceChannel.invokeMethod<String>('webViewUserAgent');
    if (ua != null && ua.isNotEmpty) {
      _cachedWebViewUa = ua;
      return ua;
    }
  } catch (_) {
    // notImplemented on iOS / older builds - fall through
  }
  return null;
}
