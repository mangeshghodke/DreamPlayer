import 'package:shared_preferences/shared_preferences.dart';

/// How the libmpv engine presents HDR/DV content.
///
/// [sdr] - convert HDR → SDR in-engine with libplacebo (`vo=gpu-next`,
/// spline tone-map, perceptual gamut, BT.709/BT.1886 output). High-quality
/// SDR result on any panel; what issue #21 asks for.
///
/// [native] - pass the source colorspace toward the display
/// (`target-colorspace-hint`) so SurfaceFlinger/panel can handle HDR/DV.
/// Needs a libplacebo/gpu-next build of libmpv and an HDR-capable surface.
///
/// [linear] - mpv-native Linear HDR: inverse tone mapping lifts the picture
/// into the HDR range and the display renders it as HDR. No shaders, no
/// custom libmpv beyond gpu-next; it is a boost, not a true Dolby Vision
/// passthrough.
///
/// [pq] / [hlg] / [bt2020] - the hdr-toys shader profiles (MIT). They need
/// `vo=gpu-next` (libplacebo) - the stock libmpv build cannot run them.
enum ToneMapMode {
  sdr('sdr', 'SDR tone-map'),
  native('native', 'Native HDR/DV'),
  linear('linear', 'Linear HDR'),
  pq('pq', 'HDR10 (BT.2100 PQ)'),
  hlg('hlg', 'HDR (BT.2100 HLG)'),
  bt2020('bt2020', 'BT.2020 wide gamut');

  const ToneMapMode(this.value, this.label);

  final String value;
  final String label;

  /// Whether the engine hands an HDR signal to the display (so the panel
  /// does the tone mapping) instead of tone-mapping in-engine.
  bool get handsHdrToDisplay =>
      this == ToneMapMode.native || this == ToneMapMode.linear;

  /// Whether this mode runs the hdr-toys shader chain (and therefore needs
  /// `vo=gpu-next`).
  bool get usesHdrToysShaders =>
      this == ToneMapMode.pq ||
      this == ToneMapMode.hlg ||
      this == ToneMapMode.bt2020;

  static ToneMapMode fromString(String? s) => switch (s) {
        'native' => ToneMapMode.native,
        'linear' => ToneMapMode.linear,
        'pq' => ToneMapMode.pq,
        'hlg' => ToneMapMode.hlg,
        'bt2020' => ToneMapMode.bt2020,
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
