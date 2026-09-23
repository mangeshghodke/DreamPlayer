import 'package:shared_preferences/shared_preferences.dart';

/// How the libmpv engine presents HDR/DV content.
///
/// [sdr] — convert HDR → SDR in-engine with libplacebo (`vo=gpu-next`,
/// spline tone-map, perceptual gamut, BT.709/BT.1886 output). High-quality
/// SDR result on any panel; what issue #21 asks for.
///
/// [native] — pass the source colorspace toward the display
/// (`target-colorspace-hint`) so SurfaceFlinger/panel can handle HDR/DV.
/// Needs a libplacebo/gpu-next build of libmpv and an HDR-capable surface.
enum ToneMapMode {
  sdr('sdr', 'SDR tone-map'),
  native('native', 'Native HDR/DV');

  const ToneMapMode(this.value, this.label);

  final String value;
  final String label;

  static ToneMapMode fromString(String? s) => switch (s) {
        'native' => ToneMapMode.native,
        _ => ToneMapMode.sdr,
      };
}

class ToneMapStore {
  ToneMapStore._();

  static const String _prefsKey = 'dreamplayer.toneMapMode';
  static const ToneMapMode _default = ToneMapMode.sdr;

  static Future<ToneMapMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return _default;
    return ToneMapMode.fromString(raw);
  }

  static Future<void> save(ToneMapMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, mode.value);
  }
}
