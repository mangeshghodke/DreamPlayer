import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS Keychain-backed persistence for the 7-day free trial start time.
///
/// The native side is `ios/Runner/TrialStore.swift` (channel
/// `dreamplayer/trial`), which stores an `Int64` millisecond timestamp as a
/// `kSecClassGenericPassword` item with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
///
/// **Why this exists:** `SharedPreferences` lives in the app container and is
/// deleted with the app. A user who deletes DreamPlayer and reinstalls from
/// the App Store got a brand-new 7-day trial every time — the "redownload"
/// loop visible in App Store Connect analytics. The Keychain item survives app
/// deletion (it only goes away if the user erases the device or removes the
/// item), so the trial resumes exactly where it stopped instead of restarting
/// from day 0.
///
/// On Android the channel does not exist (Android is permanently advanced and
/// the trial never applies), so every call here is a no-op. The channel
/// availability is probed once and cached so a missing channel is not hit on
/// every launch.
class TrialStore {
  TrialStore._();
  static final TrialStore instance = TrialStore._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/trial');

  /// Tri-state probe: null = not tried yet, false = channel missing. Static
  /// because the channel is a process-wide singleton — the probe result is too.
  static bool? _channelAvailable;

  /// Forget the cached channel-availability probe. Called by
  /// `Entitlements.resetForTest()` (and directly by tests) so each test starts
  /// from an unprobed state. Not `@visibleForTesting` because
  /// `Entitlements.resetForTest` — itself test-only — needs to call it.
  static void resetProbeForTest() {
    _channelAvailable = null;
  }

  Future<bool> get _available async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    if (_channelAvailable != null) return _channelAvailable!;
    try {
      // `getTrialStartedAt` on an empty keychain legitimately returns null,
      // so success here means "the channel answered" — not "a value exists".
      await _channel.invokeMethod<void>('getTrialStartedAt');
      _channelAvailable = true;
    } on MissingPluginException {
      _channelAvailable = false;
    } catch (_) {
      // Any other failure (locked keychain, entitlement issue) — treat the
      // store as unavailable rather than blocking app start.
      _channelAvailable = false;
    }
    return _channelAvailable!;
  }

  /// Reads the trial start time from the Keychain, or null when absent.
  Future<int?> readStartMs() async {
    if (!await _available) return null;
    try {
      final value =
          await _channel.invokeMethod<int>('getTrialStartedAt');
      if (value == null || value <= 0) return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  /// Writes the trial start time to the Keychain. Pass null to clear.
  Future<void> writeStartMs(int? ms) async {
    if (!await _available) return;
    try {
      await _channel.invokeMethod<void>('setTrialStartedAt', ms);
    } catch (_) {
      // Best effort — SharedPreferences still holds the value, so a failed
      // Keychain write degrades to the old (reinstall-vulnerable) behavior
      // rather than losing the trial entirely.
    }
  }
}
