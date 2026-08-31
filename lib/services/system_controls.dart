import 'package:flutter/services.dart';

/// Engine-agnostic OS controls.
///
/// Hosts a method channel (`dreamplayer/system`) that handles the brightness
/// (per-app window brightness) and system media volume setters/getters
/// without going through any playback engine. Used by the MPV fallback
/// engine — when mpv is active there is no [ExoPlayerController] platform
/// view to dispatch through, but the brightness/volume controls must still
/// target the OS, not just the Flutter texture overlay (so they work the
/// same way as Media3).
class SystemControls {
  SystemControls._();

  static final SystemControls instance = SystemControls._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/system');

  /// 0.0 (dim) → 1.0 (max). Pass `-1.0` to restore the system default
  /// (`BRIGHTNESS_OVERRIDE_NONE`).
  Future<void> setBrightness(double value) async {
    try {
      await _channel.invokeMethod<void>('setBrightness', {'brightness': value});
    } on PlatformException {
      // Activity isn't ready yet — the gesture will retry on next frame.
    }
  }

  Future<double> getBrightness() async {
    try {
      final raw = await _channel.invokeMethod<double>('getBrightness');
      return (raw ?? 0.5).clamp(0.0, 1.0);
    } on PlatformException {
      return 0.5;
    }
  }

  /// System media volume (0.0 → 1.0). Routes through `AudioManager`
  /// `STREAM_MUSIC` so the hardware volume keys follow the new value.
  Future<void> setSystemVolume(double value) async {
    try {
      await _channel.invokeMethod<void>('setSystemVolume', {'volume': value});
    } on PlatformException {
      // Activity gone (player closed mid-gesture) — ignore.
    }
  }

  Future<double> getSystemVolume() async {
    try {
      final raw = await _channel.invokeMethod<double>('getSystemVolume');
      return (raw ?? 1.0).clamp(0.0, 1.0);
    } on PlatformException {
      return 1.0;
    }
  }
}