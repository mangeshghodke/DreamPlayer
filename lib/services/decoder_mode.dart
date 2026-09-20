import 'package:shared_preferences/shared_preferences.dart';

enum DecoderMode {
  auto(0, 'Auto'),
  hw(1, 'Hardware'),
  sw(2, 'Software'),
  ffmpegVideo(3, 'FFmpeg Video');

  const DecoderMode(this.value, this.label);
  final int value;
  final String label;

  static DecoderMode fromValue(int? v) => DecoderMode.values.firstWhere(
        (m) => m.value == v,
        orElse: () => DecoderMode.auto,
      );

  static DecoderMode fromString(String? s) => switch (s) {
        'hw' => DecoderMode.hw,
        'sw' => DecoderMode.sw,
        'ffmpeg_video' => DecoderMode.ffmpegVideo,
        _ => DecoderMode.auto,
      };

  String get storageString => switch (this) {
        DecoderMode.auto => 'auto',
        DecoderMode.hw => 'hw',
        DecoderMode.sw => 'sw',
        DecoderMode.ffmpegVideo => 'ffmpeg_video',
      };
}

class DecoderModeStore {
  DecoderModeStore._();
  static const String _prefsKey = 'dreamplayer.decoderMode';

  static Future<DecoderMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_prefsKey);
    if (s != null) return DecoderMode.fromString(s);
    final legacy = prefs.getInt(_prefsKey);
    if (legacy != null) return DecoderMode.fromValue(legacy);
    return DecoderMode.auto;
  }

  static Future<void> save(DecoderMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, mode.storageString);
  }
}
