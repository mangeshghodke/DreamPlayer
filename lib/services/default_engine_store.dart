import 'package:shared_preferences/shared_preferences.dart';

enum DefaultEngine {
  auto('auto', 'Auto'),
  media3('media3', 'Media3'),
  mpv('mpv', 'libmpv'),
  ask('ask', 'Ask every time');

  const DefaultEngine(this.value, this.label);
  final String value;
  final String label;

  /// Whether the auto-fallback to the other engine is allowed. When the user
  /// explicitly picks Media3 or libmpv, they don't want automatic switching.
  bool get allowFallback => this == DefaultEngine.auto || this == DefaultEngine.ask;

  static DefaultEngine fromString(String? s) => switch (s) {
        'auto' => DefaultEngine.auto,
        'media3' => DefaultEngine.media3,
        'mpv' => DefaultEngine.mpv,
        'ask' => DefaultEngine.ask,
        _ => DefaultEngine.auto,
      };
}

class DefaultEngineStore {
  DefaultEngineStore._();
  static const String _prefsKey = 'dreamplayer.defaultEngine';

  static Future<DefaultEngine> load() async {
    final prefs = await SharedPreferences.getInstance();
    return DefaultEngine.fromString(prefs.getString(_prefsKey));
  }

  static Future<void> save(DefaultEngine engine) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, engine.value);
  }
}
