import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Caption font families offered in Settings. [wire] is the string sent to the
/// native renderers; [label] is what the user sees.
enum SubtitleFont {
  system('system', 'Default'),
  sansSerif('sans', 'Sans serif'),
  serif('serif', 'Serif'),
  monospace('mono', 'Monospace'),
  casual('casual', 'Casual'),
  cursive('cursive', 'Cursive');

  const SubtitleFont(this.wire, this.label);

  final String wire;
  final String label;

  static SubtitleFont fromWire(Object? value) => values.firstWhere(
        (f) => f.wire == value,
        orElse: () => SubtitleFont.system,
      );
}

/// Edge treatment behind the glyphs — the same five options YouTube's caption
/// dialog offers. Values map 1:1 to Media3's `CaptionStyleCompat.EDGE_TYPE_*`.
enum SubtitleEdge {
  none('none', 'None'),
  outline('outline', 'Outline'),
  dropShadow('shadow', 'Drop shadow'),
  raised('raised', 'Raised'),
  depressed('depressed', 'Depressed');

  const SubtitleEdge(this.wire, this.label);

  final String wire;
  final String label;

  static SubtitleEdge fromWire(Object? value) => values.firstWhere(
        (e) => e.wire == value,
        orElse: () => SubtitleEdge.outline,
      );
}

/// User-configurable subtitle appearance, applied natively on both platforms
/// (Media3 `SubtitleView` on Android, the host `SubtitleOverlayView` on
/// iOS) and persisted in shared_preferences as JSON.
@immutable
class SubtitleStyle {
  const SubtitleStyle({
    this.sizeMultiplier = 1.0,
    this.font = SubtitleFont.system,
    this.googleFont,
    this.customFontPath,
    this.customFontName,
    this.colorValue = 0xFFFFFFFF,
    this.textOpacity = 255,
    this.backgroundColorValue = 0x80000000,
    this.backgroundOpacity = 128,
    this.edge = SubtitleEdge.outline,
    this.delayMs = 0,
    this.verticalPosition = 20,
  });

  /// Multiplier around Media3's default fractional text size (1.0 = default).
  final double sizeMultiplier;

  /// Caption font family for the six built-in choices.
  final SubtitleFont font;

  /// A Google Fonts family name (e.g. `Poppins`) that overrides [font] when
  /// set. The nine bundled families work offline; any other family is fetched
  /// on demand and cached by `google_fonts`.
  final String? googleFont;

  /// Absolute path to a user-picked `.ttf`/`.otf` copied into the app's
  /// `subtitle_fonts/` dir (see `SubtitleFonts.registerCustomFont`). When set
  /// it wins over [font] and [googleFont] — it is a real file the native
  /// renderers (Media3 `Typeface.createFromFile`, iOS CoreText, libass
  /// `sub-fonts-dir`) can register directly.
  final String? customFontPath;

  /// Display name for the custom font, read from the TTF's own `name` table
  /// at pick time (the file name is not a reliable family name).
  final String? customFontName;

  /// Text color (RGB; opacity lives in [textOpacity]).
  final int colorValue;

  /// Text opacity (0-255).
  final int textOpacity;

  /// Per-cue background box (ARGB). An alpha of 0 means "no box".
  final int backgroundColorValue;

  /// Background opacity (0-255). Only used when [hasBackground].
  final int backgroundOpacity;

  /// Edge treatment behind the glyphs.
  final SubtitleEdge edge;

  /// Playback-time shift for subtitle cues (-30 s … +30 s). Positive values
  /// show each cue LATER than authored.
  final int delayMs;

  /// Vertical position offset (0-255). 0 = bottom, 255 = top. Nova default ~20.
  final int verticalPosition;

  static const _prefsKey = 'dreamplayer.subStyle';

  static const minDelayMs = -30000;
  static const maxDelayMs = 30000;
  static const minVerticalPosition = 0;
  static const maxVerticalPosition = 255;
  static const minBackgroundOpacity = 0;
  static const maxBackgroundOpacity = 255;
  static const minTextOpacity = 0;
  static const maxTextOpacity = 255;

  double get delaySeconds => delayMs / 1000.0;

  Color get color => Color(colorValue);
  Color get backgroundColor => Color(backgroundColorValue);

  /// Text color with [textOpacity] applied — what the renderers actually draw.
  int get effectiveTextColor =>
      (colorValue & 0x00FFFFFF) | ((textOpacity & 0xFF) << 24);

  /// Background color with [backgroundOpacity] applied.
  int get effectiveBackgroundColor =>
      (backgroundColorValue & 0x00FFFFFF) | ((backgroundOpacity & 0xFF) << 24);

  Color get effectiveTextColorValue => Color(effectiveTextColor);
  Color get effectiveBackgroundColorValue => Color(effectiveBackgroundColor);

  bool get hasBackground => backgroundColorValue >> 24 != 0;

  /// What the settings row shows for the current font choice.
  String get fontLabel =>
      customFontName ?? googleFont ?? font.label;

  /// True when a custom font FILE (not a family name) is the active choice.
  bool get hasCustomFontFile =>
      customFontPath != null && customFontPath!.isNotEmpty;

  /// Retained for callers that only need "is any edge drawn".
  bool get outline => edge != SubtitleEdge.none;

  SubtitleStyle copyWith({
    double? sizeMultiplier,
    SubtitleFont? font,
    String? googleFont,
    bool clearGoogleFont = false,
    String? customFontPath,
    String? customFontName,
    bool clearCustomFont = false,
    int? colorValue,
    int? textOpacity,
    int? backgroundColorValue,
    int? backgroundOpacity,
    SubtitleEdge? edge,
    int? delayMs,
    int? verticalPosition,
  }) =>
      SubtitleStyle(
        sizeMultiplier: sizeMultiplier ?? this.sizeMultiplier,
        font: font ?? this.font,
        googleFont: clearGoogleFont ? null : (googleFont ?? this.googleFont),
        customFontPath:
            clearCustomFont ? null : (customFontPath ?? this.customFontPath),
        customFontName: clearCustomFont
            ? null
            : (customFontName ?? this.customFontName),
        colorValue: colorValue ?? this.colorValue,
        textOpacity: textOpacity ?? this.textOpacity,
        backgroundColorValue:
            backgroundColorValue ?? this.backgroundColorValue,
        backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
        edge: edge ?? this.edge,
        delayMs: delayMs ?? this.delayMs,
        verticalPosition: verticalPosition ?? this.verticalPosition,
      );

  Map<String, dynamic> toJson() => {
        'size': sizeMultiplier,
        'font': font.wire,
        if (googleFont != null) 'googleFont': googleFont,
        if (customFontPath != null) 'customFontPath': customFontPath,
        if (customFontName != null) 'customFontName': customFontName,
        'color': colorValue,
        'textOpacity': textOpacity,
        'bg': backgroundColorValue,
        'bgOpacity': backgroundOpacity,
        // Written for older builds that only understood a boolean.
        'outline': outline,
        'edge': edge.wire,
        'delayMs': delayMs,
        'vPos': verticalPosition,
      };

  factory SubtitleStyle.fromJson(Map<dynamic, dynamic> json) => SubtitleStyle(
        sizeMultiplier:
            (json['size'] is num ? (json['size'] as num).toDouble() : null) ??
                1.0,
        font: SubtitleFont.fromWire(json['font']),
        googleFont: json['googleFont'] is String &&
                (json['googleFont'] as String).isNotEmpty
            ? json['googleFont'] as String
            : null,
        customFontPath: json['customFontPath'] is String &&
                (json['customFontPath'] as String).isNotEmpty
            ? json['customFontPath'] as String
            : null,
        customFontName: json['customFontName'] is String &&
                (json['customFontName'] as String).isNotEmpty
            ? json['customFontName'] as String
            : null,
        colorValue: json['color'] is int ? json['color'] as int : 0xFFFFFFFF,
        textOpacity:
            json['textOpacity'] is int ? json['textOpacity'] as int : 255,
        backgroundColorValue:
            json['bg'] is int ? json['bg'] as int : 0x80000000,
        backgroundOpacity:
            json['bgOpacity'] is int ? json['bgOpacity'] as int : 128,
        // Legacy JSON only carried `outline`; keep those users' choice.
        edge: json.containsKey('edge')
            ? SubtitleEdge.fromWire(json['edge'])
            : (json['outline'] is bool && json['outline'] == false
                ? SubtitleEdge.none
                : SubtitleEdge.outline),
        delayMs: json['delayMs'] is int ? json['delayMs'] as int : 0,
        verticalPosition:
            json['vPos'] is int ? json['vPos'] as int : 20,
      );

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }

  static Future<SubtitleStyle> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return const SubtitleStyle();
      return SubtitleStyle.fromJson(jsonDecode(raw) as Map<dynamic, dynamic>);
    } catch (_) {
      return const SubtitleStyle();
    }
  }

  /// The channel payload both native handlers accept. [fontPath] is an
  /// absolute path to a TTF that the native renderer registers; it is resolved
  /// by `SubtitleFonts` at the call site because it needs filesystem access.
  Map<String, dynamic> toChannelArgs({String? fontPath}) => {
        'size': sizeMultiplier,
        'font': font.wire,
        'googleFont': googleFont,
        'fontPath': fontPath,
        'color': effectiveTextColor,
        'bg': backgroundColorValue,
        'bgOpacity': backgroundOpacity,
        'edge': edge.wire,
        'delayMs': delayMs,
        'vPos': verticalPosition,
      };
}
