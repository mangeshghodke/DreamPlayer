import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:google_fonts/google_fonts.dart';

import '../services/subtitle_style.dart';

/// `FLUTTER_TEST` is set as a process environment variable by the test runner,
/// not as a dart-define (same detection as `AppDebugLog`).
final bool _isTest = Platform.environment.containsKey('FLUTTER_TEST');

/// Resolves a caption font family. `null` keeps the platform default, which is
/// what the "Default" option means on all three renderers.
///
/// The six built-ins used to return the web/CSS aliases (`sans-serif`, …),
/// which Android resolves but iOS does **not** — so on iPad the settings
/// preview silently kept the system font while the native overlay (which maps
/// to real UIFonts) changed, and the preview looked broken. Apple names are
/// used there instead, matching `SubtitleOverlayView.styledFont`.
String? subtitleFontFamily(SubtitleFont font) {
  final apple = defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
  return switch (font) {
    SubtitleFont.system => null,
    SubtitleFont.sansSerif => apple ? 'Helvetica Neue' : 'sans-serif',
    SubtitleFont.serif => apple ? 'Georgia' : 'serif',
    SubtitleFont.monospace => apple ? 'Menlo' : 'monospace',
    SubtitleFont.casual => apple ? 'Marker Felt' : 'casual',
    SubtitleFont.cursive => apple ? 'Snell Roundhand' : 'cursive',
  };
}

/// Flutter stand-ins for the native edge treatments. Media3 and AVFoundation
/// draw a real glyph stroke for `outline`; Flutter has no stroke on `Text`, so
/// it is faked with four offset shadows (this helper is used by the settings
/// preview and the MPV text overlay only).
List<Shadow>? subtitleShadows(SubtitleEdge edge) => switch (edge) {
      SubtitleEdge.none => null,
      SubtitleEdge.outline => const [
          Shadow(color: Colors.black, offset: Offset(-1.2, 0)),
          Shadow(color: Colors.black, offset: Offset(1.2, 0)),
          Shadow(color: Colors.black, offset: Offset(0, -1.2)),
          Shadow(color: Colors.black, offset: Offset(0, 1.2)),
        ],
      SubtitleEdge.dropShadow => const [
          Shadow(color: Colors.black87, blurRadius: 3, offset: Offset(2, 2)),
        ],
      SubtitleEdge.raised => const [
          Shadow(color: Colors.black87, blurRadius: 1, offset: Offset(2, 2)),
          Shadow(color: Colors.white70, blurRadius: 1, offset: Offset(-1, -1)),
        ],
      SubtitleEdge.depressed => const [
          Shadow(color: Colors.black87, blurRadius: 1, offset: Offset(-2, -2)),
          Shadow(color: Colors.white54, blurRadius: 1, offset: Offset(1, 1)),
        ],
    };

/// The one TextStyle builder shared by the settings preview and the MPV
/// subtitle overlay, so what the preview shows is what MPV draws.
TextStyle subtitleTextStyle(
  SubtitleStyle style, {
  required double fontSize,
  double height = 1.4,
  FontWeight fontWeight = FontWeight.w500,
}) {
  final base = TextStyle(
    color: style.effectiveTextColorValue,
    fontSize: fontSize,
    height: height,
    fontWeight: fontWeight,
    fontFamily: subtitleFontFamily(style.font),
    backgroundColor:
        style.hasBackground ? style.effectiveBackgroundColorValue : null,
    shadows: subtitleShadows(style.edge),
  );
  // A user-picked font FILE wins over any family name. Flutter can register
  // an arbitrary TTF via FontLoader, so the preview shows the real typeface.
  final customPath = style.customFontPath;
  if (customPath != null && customPath.isNotEmpty) {
    final family = style.customFontName ?? 'DreamPlayerCustomFont';
    if (_isTest) return base.copyWith(fontFamily: family);
    try {
      final loader = FontLoader(family);
      loader.addFont(Future(() async {
        final file = File(customPath);
        if (!await file.exists()) {
          throw StateError('custom font file missing: $customPath');
        }
        final bytes = await file.readAsBytes();
        return ByteData.view(bytes.buffer);
      }));
      // FontLoader.load() must be called to register; the returned future is
      // fire-and-forget for the first paint, the next frame uses the font.
      loader.load();
      return base.copyWith(
        fontFamily: family,
        fontFamilyFallback: [base.fontFamily ?? 'sans-serif'],
        fontWeight: FontWeight.w400,
      );
    } catch (_) {
      return base;
    }
  }
  final google = style.googleFont;
  if (google == null || google.isEmpty) return base;
  // In a widget test the package would start a real font load (disk/HTTP) from
  // a synchronously-built style; tests only assert the resolved family name.
  if (_isTest) return base.copyWith(fontFamily: google);
  try {
    // google_fonts registers the family with the engine and kicks off the
    // load, which is what makes the preview (and the MPV overlay) show it.
    // Regular weight only: that is the file shipped/registered for the native
    // renderers, and asking for w500 would make google_fonts fetch a second
    // variant the player never uses.
    return GoogleFonts.getFont(
      google,
      textStyle: base.copyWith(fontWeight: FontWeight.w400),
    );
  } catch (_) {
    return base;
  }
}

/// The chosen font only — used to draw a font's own name in a picker row,
/// without the caption's colours, box or edge treatment leaking into the UI.
TextStyle subtitleFontPreview(SubtitleStyle style, {double fontSize = 16}) {
  final styled = subtitleTextStyle(
    style,
    fontSize: fontSize,
    fontWeight: FontWeight.w400,
  );
  // Rebuild rather than copyWith(color: null): a null argument to copyWith
  // means "keep the existing value", so the caption colour would survive.
  return TextStyle(
    fontFamily: styled.fontFamily,
    fontFamilyFallback: styled.fontFamilyFallback,
    fontSize: fontSize,
    fontWeight: FontWeight.w400,
  );
}
