import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-configurable subtitle appearance, applied natively on both platforms
/// (Media3 `SubtitleView` on Android, the host `SubtitleOverlayView` on
/// iOS) and persisted in shared_preferences as JSON.
@immutable
class SubtitleStyle {
  const SubtitleStyle({
    this.sizeMultiplier = 1.0,
    this.colorValue = 0xFFFFFFFF,
    this.backgroundColorValue = 0x80000000,
    this.backgroundOpacity = 128,
    this.outline = true,
    this.delayMs = 0,
    this.verticalPosition = 20,
  });

  /// Multiplier around Media3's default fractional text size (1.0 = default).
  final double sizeMultiplier;

  /// Text color (ARGB).
  final int colorValue;

  /// Per-cue background box (ARGB). An alpha of 0 means "no box".
  final int backgroundColorValue;

  /// Background opacity (0-255). Only used when backgroundColorValue alpha > 0.
  final int backgroundOpacity;

  /// Black outline/shadow behind the glyphs for readability.
  final bool outline;

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

  double get delaySeconds => delayMs / 1000.0;

  Color get color => Color(colorValue);
  Color get backgroundColor => Color(backgroundColorValue);

  bool get hasBackground => backgroundColorValue >> 24 != 0;

  SubtitleStyle copyWith({
    double? sizeMultiplier,
    int? colorValue,
    int? backgroundColorValue,
    int? backgroundOpacity,
    bool? outline,
    int? delayMs,
    int? verticalPosition,
  }) =>
      SubtitleStyle(
        sizeMultiplier: sizeMultiplier ?? this.sizeMultiplier,
        colorValue: colorValue ?? this.colorValue,
        backgroundColorValue:
            backgroundColorValue ?? this.backgroundColorValue,
        backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
        outline: outline ?? this.outline,
        delayMs: delayMs ?? this.delayMs,
        verticalPosition: verticalPosition ?? this.verticalPosition,
      );

  Map<String, dynamic> toJson() => {
        'size': sizeMultiplier,
        'color': colorValue,
        'bg': backgroundColorValue,
        'bgOpacity': backgroundOpacity,
        'outline': outline,
        'delayMs': delayMs,
        'vPos': verticalPosition,
      };

  factory SubtitleStyle.fromJson(Map<dynamic, dynamic> json) => SubtitleStyle(
        sizeMultiplier:
            (json['size'] is num ? (json['size'] as num).toDouble() : null) ??
                1.0,
        colorValue: json['color'] is int ? json['color'] as int : 0xFFFFFFFF,
        backgroundColorValue:
            json['bg'] is int ? json['bg'] as int : 0x80000000,
        backgroundOpacity:
            json['bgOpacity'] is int ? json['bgOpacity'] as int : 128,
        outline: json['outline'] is bool ? json['outline'] as bool : true,
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

  /// The channel payload both native handlers accept.
  Map<String, dynamic> toChannelArgs() => {
        'size': sizeMultiplier,
        'color': colorValue,
        'bg': backgroundColorValue,
        'bgOpacity': backgroundOpacity,
        'outline': outline,
        'delayMs': delayMs,
        'vPos': verticalPosition,
      };
}
