import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One selectable accent, used to seed the app's [ColorScheme].
class Accent {
  const Accent(this.id, this.label, this.color);

  final String id;
  final String label;
  final Color color;
}

/// Persists the user's accent colour choice (issue #34, item 5).
///
/// The whole app theme is derived with `ColorScheme.fromSeed`, so switching
/// accent is a single seed swap rather than a second theme per colour.
class AccentStore extends ChangeNotifier {
  AccentStore._();

  static const String _prefsKey = 'dreamplayer.accent';

  /// Seeds chosen to stay legible on the app's near-black background
  /// (`#0E0E11`) — none of them is so light it disappears against it.
  static const List<Accent> accents = [
    Accent('violet', 'Violet', Color(0xFF7C4DFF)),
    Accent('blue', 'Blue', Color(0xFF3D7BFF)),
    Accent('cyan', 'Cyan', Color(0xFF00B5D8)),
    Accent('green', 'Green', Color(0xFF2FBF71)),
    Accent('amber', 'Amber', Color(0xFFFFA726)),
    Accent('pink', 'Pink', Color(0xFFFF4D8D)),
  ];

  static final AccentStore instance = AccentStore._();

  /// Index into [accents]; 0 is the original violet.
  int _index = 0;

  Accent get accent => accents[_index.clamp(0, accents.length - 1)];

  static Future<AccentStore> load() async {
    final store = instance;
    // Authoritative reset, same reasoning as LayoutStore.load(): a load with
    // no stored pref must not inherit a previous in-memory value.
    store._index = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_prefsKey);
      if (id == null) return store;
      final found = accents.indexWhere((a) => a.id == id);
      if (found >= 0) store._index = found;
    } catch (_) {
      // Keep the default accent if prefs are unavailable.
    }
    return store;
  }

  Future<void> setAccent(Accent value) async {
    final next = accents.indexWhere((a) => a.id == value.id);
    if (next < 0 || next == _index) return;
    _index = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, value.id);
    } catch (_) {
      // The in-memory accent still applies for this session.
    }
  }
}
