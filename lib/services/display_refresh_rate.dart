import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_displaymode/flutter_displaymode.dart';

/// Requests the highest refresh rate supported by the display.
///
/// Flutter on Android defaults to 60 Hz even when the display supports
/// 90/120/120 Hz. This call lets the app run at the panel's native rate.
/// iOS/iPad (ProMotion) unlocks high refresh rates automatically via
/// `CADisableMinimumFrameDurationOnPhone` in Info.plist.
Future<void> useNativeDisplayRefreshRate() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (_) {
    // Best-effort; fall back to the system default.
  }
}
