import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Hide spoilers" (competitor-gap #10): blur the artwork of episodes you
/// have not watched yet, so a season list does not hand away the ending.
///
/// Off by default - existing installs see nothing change. The value is
/// session state read live by [EpisodeRow] and the details screen, so
/// flipping the switch updates what is on screen without a reload.
class HideSpoilersStore extends ChangeNotifier {
  HideSpoilersStore._();

  static final HideSpoilersStore instance = HideSpoilersStore._();

  static const String prefsKey = 'dreamplayer.hideSpoilers';

  bool _enabled = false;

  bool get enabled => _enabled;

  /// True when this episode's still/overview must be hidden.
  ///
  /// [watched] is whether the file already carries a watched mark; an
  /// unknown state (callers that cannot tell) counts as NOT watched, which
  /// is the safe direction - a binge watcher wants everything they have not
  /// finished hidden rather than revealed.
  bool spoils({required bool watched}) => _enabled && !watched;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(prefsKey) ?? false;
    if (v != _enabled) {
      _enabled = v;
      notifyListeners();
    }
  }

  Future<void> setEnabled(bool v) async {
    if (v == _enabled) return;
    _enabled = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, v);
  }
}