import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/subtitle_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SubtitleStyle custom font file', () {
    test('json round-trips customFontPath/customFontName', () {
      final style = const SubtitleStyle().copyWith(
        customFontPath: '/data/app/support/subtitle_fonts/custom_MyFont.ttf',
        customFontName: 'My Custom Font',
        clearGoogleFont: true,
      );
      final back = SubtitleStyle.fromJson(
        jsonDecode(jsonEncode(style.toJson())) as Map<String, dynamic>,
      );
      expect(back.customFontPath, style.customFontPath);
      expect(back.customFontName, 'My Custom Font');
      expect(back.googleFont, isNull);
    });

    test('fontLabel prefers the custom font name over google and built-in', () {
      final withCustom = const SubtitleStyle(
        googleFont: 'Poppins',
        customFontPath: '/x/custom_a.ttf',
        customFontName: 'Anime Ace',
      );
      expect(withCustom.fontLabel, 'Anime Ace');
      expect(withCustom.hasCustomFontFile, isTrue);

      final googleOnly = const SubtitleStyle(googleFont: 'Poppins');
      expect(googleOnly.fontLabel, 'Poppins');
      expect(googleOnly.hasCustomFontFile, isFalse);

      final builtin = const SubtitleStyle();
      expect(builtin.fontLabel, 'Default');
    });

    test('copyWith can clear the custom font without touching googleFont', () {
      final style = const SubtitleStyle(
        googleFont: 'Lato',
        customFontPath: '/x.ttf',
        customFontName: 'X',
      );
      final cleared = style.copyWith(clearCustomFont: true);
      expect(cleared.customFontPath, isNull);
      expect(cleared.customFontName, isNull);
      expect(cleared.googleFont, 'Lato'); // untouched
      expect(cleared.fontLabel, 'Lato');
    });

    test('choosing a built-in clears both google and custom font', () {
      final style = const SubtitleStyle(
        googleFont: 'Lato',
        customFontPath: '/x.ttf',
        customFontName: 'X',
      ).copyWith(font: SubtitleFont.serif, clearGoogleFont: true, clearCustomFont: true);
      expect(style.font, SubtitleFont.serif);
      expect(style.googleFont, isNull);
      expect(style.customFontPath, isNull);
      expect(style.fontLabel, 'Serif');
    });

    test('legacy JSON without custom fields still loads', () {
      final legacy = SubtitleStyle.fromJson(jsonDecode(jsonEncode({
        'size': 1.2,
        'font': 'mono',
        'googleFont': 'Poppins',
        'color': 0xFFFFFFFF,
        'textOpacity': 255,
        'bg': 0x80000000,
        'bgOpacity': 128,
        'outline': true,
        'edge': 'shadow',
        'delayMs': 250,
        'vPos': 20,
      })) as Map<String, dynamic>);
      expect(legacy.customFontPath, isNull);
      expect(legacy.hasCustomFontFile, isFalse);
      expect(legacy.fontLabel, 'Poppins');
      expect(legacy.font, SubtitleFont.monospace);
    });

    test('toChannelArgs carries the style fields; fontPath is caller-resolved', () {
      final style = const SubtitleStyle(
        customFontPath: '/x.ttf',
        customFontName: 'X',
      );
      final args = style.toChannelArgs(fontPath: '/x.ttf');
      expect(args['fontPath'], '/x.ttf');
      expect(args['font'], 'system');
    });

    test('save/load persists the custom font choice', () async {
      SharedPreferences.setMockInitialValues({});
      final style = const SubtitleStyle().copyWith(
        customFontPath: '/data/subtitle_fonts/custom_A.ttf',
        customFontName: 'Font A',
      );
      await style.save();
      final loaded = await SubtitleStyle.load();
      expect(loaded.customFontPath, '/data/subtitle_fonts/custom_A.ttf');
      expect(loaded.customFontName, 'Font A');
      expect(loaded.fontLabel, 'Font A');
    });
  });
}
