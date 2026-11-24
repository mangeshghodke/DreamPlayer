import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Keep screen on": while the player screen is open, the display must not
/// auto-lock (user report 2026-11-24: "screen stay awake is not working, it
/// follows auto screen off" on 0.5.7/0.5.8 - the Media3 platform view set
/// `keepScreenOn` on its own platform-view window, which hybrid composition
/// does not reliably propagate to the activity window, and the MPV surface
/// view set nothing at all).
///
/// The pref key is read natively as `flutter.dreamplayer.keepScreenOn`
/// (shared_preferences prefixes keys with `flutter.` on both Android and iOS),
/// so iOS can gate `isIdleTimerDisabled` at open without a channel round trip.
/// Default ON - a video player keeping the screen awake while watching is the
/// expected behaviour (VLC/Nova/YouTube all do it).
class KeepScreenOnStore extends ChangeNotifier {
  KeepScreenOnStore._();

  static const String prefsKey = 'dreamplayer.keepScreenOn';

  static final KeepScreenOnStore instance = KeepScreenOnStore._();

  bool _enabled = true;

  /// Default ON: see class doc.
  bool get enabled => _enabled;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(prefsKey) ?? true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, value);
    notifyListeners();
  }
}
