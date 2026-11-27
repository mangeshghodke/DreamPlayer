import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Audio-only cover display style (user request 2026-11-27): the default is
/// the VINYL DISC with the embedded art as its face (DJ-scratchable); the
/// alternative is a plain rounded cover-art card (Mpv-infinity's look) with no
/// disc chrome and no scratch gestures. Toggled from the player top bar while
/// audio is playing.
class AudioArtStyleStore extends ChangeNotifier {
  AudioArtStyleStore._();

  static const String prefsKey = 'dreamplayer.audioPlainArt';

  static final AudioArtStyleStore instance = AudioArtStyleStore._();

  bool _plainArt = false;

  /// Default false = vinyl disc.
  bool get plainArt => _plainArt;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _plainArt = prefs.getBool(prefsKey) ?? false;
    notifyListeners();
  }

  Future<void> setPlainArt(bool value) async {
    _plainArt = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, value);
    notifyListeners();
  }
}
