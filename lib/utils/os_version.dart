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

/// True when the device runs iOS 26+ — the floor of the AetherEngine MetalFX
/// upscale stage (`#available(iOS 26, ...)` in the engine), so the Settings
/// toggle is only offered where it can actually do something.
Future<bool> isIos26OrLater() async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return false;
  final major = await osMajorVersion();
  return major != null && major >= 26;
}
