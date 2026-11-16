import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How a network browser presents its entries.
///
/// [list] is the classic rows view (one line per file/folder).
/// [grid] is the tiles view (Windows 11 "medium icons"): artwork on top,
/// name below, folders shown as folder tiles.
enum BrowserViewMode {
  list('list'),
  grid('grid');

  const BrowserViewMode(this.value);

  final String value;

  static BrowserViewMode fromString(String? s) => switch (s) {
        'grid' => BrowserViewMode.grid,
        _ => BrowserViewMode.list,
      };
}

/// Persists the List / Grid choice for the network browsers.
///
/// One preference for every browser (SMB, WebDAV, FTP, UPnP, Jellyfin) -
/// switching to Grid in one switches them all, which is what a user expects
/// from a view setting and avoids five independent toggles to get wrong.
///
/// The store is a [ChangeNotifier] so an open browser rebuilds immediately
/// when the choice changes; the screens listen through a `ListenableBuilder`.
class BrowserViewStore extends ChangeNotifier {
  BrowserViewStore._();

  static const String _prefsKey = 'dreamplayer.browserView';

  static final BrowserViewStore instance = BrowserViewStore._();

  BrowserViewMode _mode = BrowserViewMode.list;

  BrowserViewMode get mode => _mode;

  bool get isGrid => _mode == BrowserViewMode.grid;

  bool get isList => _mode == BrowserViewMode.list;

  /// Reads the persisted choice. Safe to call more than once.
  static Future<BrowserViewStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    instance._mode =
        BrowserViewMode.fromString(prefs.getString(_prefsKey));
    return instance;
  }

  Future<void> setMode(BrowserViewMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, mode.value);
  }
}
