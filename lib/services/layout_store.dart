import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the library grids render their items.
enum LibraryViewMode {
  /// Today's behaviour: responsive poster grid sized from the card aspect.
  poster('poster'),

  /// Same grid, tighter cards and a shorter text block — fits more titles on
  /// screen at the cost of smaller art.
  ///
  /// A true list view is deliberately not here: neither [VideoCard] nor
  /// [FolderCard] has a wide/row presentation, so it needs a new row widget
  /// that receives the item data (the grids only pass a finished card
  /// builder). That is its own change rather than a mode flag.
  compact('compact');

  const LibraryViewMode(this.value);
  final String value;

  static LibraryViewMode fromString(String? s) => switch (s) {
        'compact' => LibraryViewMode.compact,
        _ => LibraryViewMode.poster,
      };
}

/// Persists the library layout preference (issue #34, items 6).
///
/// Defaults preserve the current behaviour exactly: poster mode and an
/// automatic column count derived from the available width.
class LayoutStore extends ChangeNotifier {
  LayoutStore._();

  static const String _prefsKey = 'dreamplayer.layout';

  /// Widest grid we will ever build, so a large tablet/TV doesn't render
  /// unreadable slivers.
  static const int maxColumns = 8;

  static final LayoutStore instance = LayoutStore._();

  LibraryViewMode _mode = LibraryViewMode.poster;
  int _columns = 0; // 0 = automatic

  LibraryViewMode get mode => _mode;

  /// 0 means "automatic" — derive the column count from the width.
  int get columns => _columns;

  static Future<LayoutStore> load() async {
    final store = instance;
    // Reset first so a load is authoritative. Without this, a missing pref
    // would leave whatever a previous load left in memory, which is only
    // correct on a cold start and makes the store untestable.
    store._mode = LibraryViewMode.poster;
    store._columns = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return store;
      // Stored as "mode:columns" so both settings share one key.
      final parts = raw.split(':');
      store._mode = LibraryViewMode.fromString(parts.first);
      store._columns = (parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0)
          .clamp(0, maxColumns);
    } catch (_) {
      // A corrupt/absent pref must never stop the library rendering.
    }
    return store;
  }

  Future<void> setMode(LibraryViewMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    await _persist();
  }

  /// [columns] of 0 restores the automatic responsive count.
  Future<void> setColumns(int columns) async {
    final clamped = columns.clamp(0, maxColumns);
    if (_columns == clamped) return;
    _columns = clamped;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, '$_mode:$_columns');
    } catch (_) {
      // Non-fatal: the in-memory value still applies for this session.
    }
  }

  /// Upper bound on columns for a given width, used both by the automatic
  /// ladder and to clamp a user override so an explicit "x6" can't produce
  /// unreadable cards on a small phone.
  static int maxColumnsForWidth(double width) {
    if (width >= 1400) return maxColumns;
    if (width >= 1000) return 6;
    if (width >= 760) return 4;
    if (width >= 480) return 3;
    return 2;
  }

  /// The automatic ladder that existed before this preference existed.
  static int autoColumnsForWidth(double width) {
    if (width >= 1000) return 6;
    if (width >= 760) return 4;
    if (width >= 480) return 3;
    return 2;
  }

  /// Column count to build for [width] honouring the user's override.
  int columnsForWidth(double width) {
    final cap = maxColumnsForWidth(width);
    if (_columns <= 0) return autoColumnsForWidth(width);
    return _columns > cap ? cap : _columns;
  }

  /// Height of the text block under a card. Compact mode trims it so more
  /// rows fit on screen.
  double textBlockHeight(double base) => _mode == LibraryViewMode.compact
      ? base * 0.62
      : base;
}
