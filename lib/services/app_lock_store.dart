import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App lock state (competitor-gap #8): Face ID / Touch ID / device passcode
/// gate on app launch and on resume from background, plus per-folder locks.
///
/// Persistence:
/// - `dreamplayer.appLock` - master switch (bool)
/// - `dreamplayer.appLockOnLaunch` - also lock on every cold start (bool)
/// - `dreamplayer.appLockOnResume` - lock when returning from background (bool)
/// - `dreamplayer.appLockFolders` - JSON string list of locked folder ids
///
/// Session-only state (never persisted):
/// - `_unlockedThisSession` - the app-level gate was passed since launch
/// - `_unlockedFolderIds` - folders unlocked this session
///
/// The auth itself is delegated to the `local_auth` plugin, which uses the
/// device's own biometric / passcode - DreamPlayer never sees or stores a PIN.
class AppLockStore extends ChangeNotifier {
  AppLockStore._();

  static final AppLockStore instance = AppLockStore._();

  static const _kEnabled = 'dreamplayer.appLock';
  static const _kOnLaunch = 'dreamplayer.appLockOnLaunch';
  static const _kOnResume = 'dreamplayer.appLockOnResume';
  static const _kFolders = 'dreamplayer.appLockFolders';

  final LocalAuthentication _auth = LocalAuthentication();

  bool _enabled = false;
  bool _lockOnLaunch = true;
  bool _lockOnResume = true;
  Set<String> _lockedFolderIds = {};

  /// Session-only: the app-level gate has been passed since launch.
  bool _unlockedThisSession = false;
  /// Session-only: folder ids unlocked since launch.
  final Set<String> _unlockedFolderIds = {};

  bool get enabled => _enabled;
  bool get lockOnLaunch => _lockOnLaunch;
  bool get lockOnResume => _lockOnResume;
  Set<String> get lockedFolderIds => Set.unmodifiable(_lockedFolderIds);

  /// True when the app-level lock screen should be shown right now.
  ///
  /// Cold launch always starts locked when the feature is on (the session
  /// flag starts false). Returning from background re-locks when
  /// [lockOnResume] is set. [lockOnLaunch] only matters as a hint that the
  /// feature is armed at all - the cold-start case is covered by the session
  /// flag starting false.
  bool get locked => _enabled && !_unlockedThisSession;

  bool isFolderLocked(String folderId) =>
      _lockedFolderIds.contains(folderId) &&
      !_unlockedFolderIds.contains(folderId);

  /// True when the device has any usable credential (biometric or device
  /// passcode). When false the lock cannot be armed - enabling is refused.
  Future<bool> canAuthenticate() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final deviceSupported = await _auth.isDeviceSupported();
      return canCheck || deviceSupported;
    } on PlatformException {
      return false;
    }
  }

  /// Lists the enrolled biometric types (for the settings subtitle). Empty
  /// when only a device passcode is available.
  Future<List<BiometricType>> availableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } on PlatformException {
      return const [];
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    _lockOnLaunch = prefs.getBool(_kOnLaunch) ?? true;
    _lockOnResume = prefs.getBool(_kOnResume) ?? true;
    final raw = prefs.getString(_kFolders);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List).cast<String>();
        _lockedFolderIds = list.toSet();
      } catch (_) {
        _lockedFolderIds = {};
      }
    }
    // A fresh process always starts locked when the feature is on.
    _unlockedThisSession = false;
    notifyListeners();
  }

  Future<bool> setEnabled(bool v) async {
    if (v) {
      // Arming the lock requires a working credential - refuse otherwise so
      // the user is never locked out with no way back in.
      final ok = await canAuthenticate();
      if (!ok) return false;
      // Prove the credential actually works before persisting the switch.
      final authed = await authenticate(reason: 'Confirm to enable App lock');
      if (!authed) return false;
    }
    _enabled = v;
    if (!v) {
      // Disabling clears every folder lock too.
      _lockedFolderIds = {};
      _unlockedFolderIds.clear();
      await _persistFolders();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, v);
    notifyListeners();
    return true;
  }

  Future<void> setLockOnLaunch(bool v) async {
    _lockOnLaunch = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnLaunch, v);
    notifyListeners();
  }

  Future<void> setLockOnResume(bool v) async {
    _lockOnResume = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnResume, v);
    notifyListeners();
  }

  /// Runs the device credential prompt. Returns true when the user
  /// authenticated. [biometricOnly] is false by default so the device
  /// passcode is accepted as a fallback.
  Future<bool> authenticate({
    String reason = 'Unlock DreamPlayer',
    bool biometricOnly = false,
  }) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          biometricOnly: biometricOnly,
          stickyAuth: true,
        ),
      );
    } on PlatformException {
      return false;
    }
  }

  /// Called when the app-level gate is passed. Returns true on success.
  Future<bool> unlockApp() async {
    final ok = await authenticate(reason: 'Unlock DreamPlayer');
    if (ok) {
      _unlockedThisSession = true;
      notifyListeners();
    }
    return ok;
  }

  /// Re-locks the app (called when the app returns to the foreground and
  /// [lockOnResume] is on). No-op when the feature is off.
  void relockOnResume() {
    if (_enabled && _lockOnResume && _unlockedThisSession) {
      _unlockedThisSession = false;
      _unlockedFolderIds.clear();
      notifyListeners();
    }
  }

  /// Per-folder lock toggle. Locking requires a successful auth so a folder
  /// can never be locked without a way back in.
  Future<bool> setFolderLocked(String folderId, bool locked) async {
    if (locked) {
      final ok = await authenticate(reason: 'Confirm to lock this folder');
      if (!ok) return false;
      _lockedFolderIds.add(folderId);
    } else {
      _lockedFolderIds.remove(folderId);
      _unlockedFolderIds.remove(folderId);
    }
    await _persistFolders();
    notifyListeners();
    return true;
  }

  /// Unlocks a folder for this session. Returns true on success.
  Future<bool> unlockFolder(String folderId) async {
    final ok = await authenticate(reason: 'Unlock this folder');
    if (ok) {
      _unlockedFolderIds.add(folderId);
      notifyListeners();
    }
    return ok;
  }

  Future<void> _persistFolders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFolders, jsonEncode(_lockedFolderIds.toList()));
  }
}
