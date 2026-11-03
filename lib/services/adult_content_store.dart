import 'package:shared_preferences/shared_preferences.dart';

const String includeAdultPrefsKey = 'dreamplayer.metadataIncludeAdult';

/// Whether metadata lookups may return adult titles (issue #46, part 1).
///
/// TMDB is asked `include_adult=false` everywhere by default, so an adult
/// anime/hentai file resolves to nothing no matter how well the filename
/// parses. Measured on the live API for `query=hentai`: `false` returns 20
/// results of which **0** are adult, `true` returns the same 20 of which **4**
/// are (`Hentai Vixens`, `Hentai Sex School`, `Hentai Ass Fanatic`). So this is
/// a single query parameter, not a client-side filter - nothing else in the app
/// inspects or strips adult results.
///
/// Default is **off**, preserving today's behaviour for existing installs.
///
/// Deliberately its own file rather than living in `tmdb_client.dart`: that
/// file imports the provider-adapter seam, so keeping the store here would make
/// the two import each other.
class AdultContentStore {
  AdultContentStore({Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  bool _includeAdult = false;
  bool _loaded = false;

  /// Last value any instance loaded or saved. Lets synchronous readers
  /// (e.g. poster alignment in [CachedImage]) see the toggle without an
  /// await; false until something has loaded it.
  static bool _sharedIncludeAdult = false;

  /// Synchronous view of the toggle, updated by every [load]/[setIncludeAdult].
  static bool get includeAdultNow => _sharedIncludeAdult;

  /// Cached value; false until [load] has run.
  bool get includeAdult => _includeAdult;

  Future<bool> load() async {
    if (_loaded) return _includeAdult;
    try {
      final prefs = await _preferences();
      _includeAdult = prefs.getBool(includeAdultPrefsKey) ?? false;
    } catch (_) {
      // A missing or reset preferences store must not break metadata
      // resolution; the safe default is the pre-existing behaviour.
      _includeAdult = false;
    }
    _loaded = true;
    _sharedIncludeAdult = _includeAdult;
    return _includeAdult;
  }

  Future<bool> setIncludeAdult(bool value) async {
    _includeAdult = value;
    _loaded = true;
    _sharedIncludeAdult = value;
    try {
      final prefs = await _preferences();
      await prefs.setBool(includeAdultPrefsKey, value);
    } catch (_) {
      // Keep the in-memory value: the toggle must still take effect this
      // session even if persisting failed.
    }
    return _includeAdult;
  }
}