import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the library grids render their items.
enum LibraryViewMode {
  /// Today's behaviour: responsive poster grid sized from the card aspect.
  poster('poster'),

  /// Same grid, tighter cards and a shorter text block — fits more titles on
  /// screen at the cost of smaller art.
  ///
  compact('compact'),

  /// One wide row per title, rendered by `LibraryListRow`.
  list('list');

  const LibraryViewMode(this.value);
  final String value;

  static LibraryViewMode fromString(String? s) => switch (s) {
        'compact' => LibraryViewMode.compact,
        'list' => LibraryViewMode.list,
        _ => LibraryViewMode.poster,
      };
}

/// How large the thumbnail at the left of an episode / file row is
/// (issue #38, items 1-3).
///
/// Deliberately kept as a bare enum with no Flutter geometry here, so this
/// store stays pure Dart and unit-testable. The pixel sizes live in
/// `EpisodeThumbGeometry` (lib/widgets/episode_row.dart), which is the widget
/// layer's business.
enum EpisodeThumbSize {
  /// Today's effective size. Note the old `_Poster` asked for 48x72 but
  /// `ListTile` clamped `leading` to 56 px tall, so `small` reproduces the
  /// size users actually saw rather than the size the code claimed.
  small('small'),

  medium('medium'),
  large('large');

  const EpisodeThumbSize(this.value);
  final String value;

  static EpisodeThumbSize fromString(String? s) => switch (s) {
        'medium' => EpisodeThumbSize.medium,
        'large' => EpisodeThumbSize.large,
        _ => EpisodeThumbSize.small,
      };
}

/// Persists the library layout preference (issue #34, items 6) and the
/// episode-row thumbnail size (issue #38, items 1-3).
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
  EpisodeThumbSize _thumbSize = EpisodeThumbSize.small;

  LibraryViewMode get mode => _mode;

  /// Thumbnail size for episode/file rows.
  EpisodeThumbSize get thumbSize => _thumbSize;

  /// 0 means "automatic" — derive the column count from the width.
  int get columns => _columns;

  static Future<LayoutStore> load() async {
    final store = instance;
    // Reset first so a load is authoritative. Without this, a missing pref
    // would leave whatever a previous load left in memory, which is only
    // correct on a cold start and makes the store untestable.
    store._mode = LibraryViewMode.poster;
    store._columns = 0;
    store._thumbSize = EpisodeThumbSize.small;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return store;
      // Stored as "mode:columns:thumb" so all settings share one key. The
      // thumb segment is optional, so a value written before issue #38 landed
      // (only two segments) still loads and keeps the default.
      final parts = raw.split(':');
      store._mode = LibraryViewMode.fromString(parts.first);
      store._columns = (parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0)
          .clamp(0, maxColumns);
      store._thumbSize = EpisodeThumbSize.fromString(
        parts.length > 2 ? parts[2] : null,
      );
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

  Future<void> setThumbSize(EpisodeThumbSize size) async {
    if (_thumbSize == size) return;
    _thumbSize = size;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // `value`, not the enum itself: '\$mode' would serialise as
      // "LibraryViewMode.compact", which fromString() never matches, so the
      // setting silently reverted to poster on every load.
      await prefs.setString(
        _prefsKey,
        '${_mode.value}:$_columns:${_thumbSize.value}',
      );
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
  ///
  /// An explicit choice is honoured on any screen width — the request was
  /// "see more titles at once", so silently clamping "4" back to the 2 that a
  /// 360dp phone fits would make the setting look broken. Only the absolute
  /// bounds in [setColumns] apply.
  int columnsForWidth(double width) {
    // A list is one row per title by definition.
    if (_mode == LibraryViewMode.list) return 1;
    if (_columns <= 0) return autoColumnsForWidth(width);
    return _columns;
  }

  bool get isList => _mode == LibraryViewMode.list;

  /// Height of the text block under a card. Compact mode trims it so more
  /// rows fit on screen.
  double textBlockHeight(double base) => _mode == LibraryViewMode.compact
      ? base * 0.62
      : base;
}
