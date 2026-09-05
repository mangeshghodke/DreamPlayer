import 'package:shared_preferences/shared_preferences.dart';

enum DefaultEngine {
  media3('media3', 'Media3'),
  mpv('mpv', 'libmpv'),
  ask('ask', 'Ask every time');

  const DefaultEngine(this.value, this.label);
  final String value;
  final String label;

  static DefaultEngine fromString(String? s) => switch (s) {
        'mpv' => DefaultEngine.mpv,
        'ask' => DefaultEngine.ask,
        _ => DefaultEngine.media3,
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
