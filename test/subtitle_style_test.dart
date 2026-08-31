import 'package:dream_player/screens/subtitle_settings_screen.dart';
import 'package:dream_player/services/subtitle_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SubtitleStyle', () {
    test('defaults', () {
      const style = SubtitleStyle();
      expect(style.sizeMultiplier, 1.0);
      expect(style.colorValue, 0xFFFFFFFF);
      expect(style.backgroundColorValue, 0x80000000);
      expect(style.outline, isTrue);
      expect(style.delayMs, 0);
      expect(style.hasBackground, isTrue);
    });

    test('no-background detection (alpha 0)', () {
      const style = SubtitleStyle(backgroundColorValue: 0x00000000);
      expect(style.hasBackground, isFalse);
    });

    test('json round-trip preserves fields', () async {
      SharedPreferences.setMockInitialValues({});
      const original = SubtitleStyle(
        sizeMultiplier: 1.25,
        colorValue: 0xFFFFEB3B,
        backgroundColorValue: 0xF0000000,
        outline: false,
        delayMs: 1500,
      );
      await original.save();
      final loaded = await SubtitleStyle.load();
      expect(loaded.sizeMultiplier, original.sizeMultiplier);
      expect(loaded.colorValue, original.colorValue);
      expect(loaded.backgroundColorValue, original.backgroundColorValue);
      expect(loaded.outline, original.outline);
      expect(loaded.delayMs, original.delayMs);
    });

    test('corrupt json falls back to defaults', () async {
      SharedPreferences.setMockInitialValues({
        'dreamplayer.subStyle': '{not json',
      });
      final loaded = await SubtitleStyle.load();
      expect(loaded.sizeMultiplier, 1.0);
      expect(loaded.delayMs, 0);
    });

    test('channel args carry every field natively typed', () {
      const style = SubtitleStyle(
        sizeMultiplier: 1.5,
        colorValue: 0xFF80DEEA,
        backgroundColorValue: 0x00000000,
        outline: false,
        delayMs: -2000,
      );
      final args = style.toChannelArgs();
      expect(args['size'], 1.5);
      expect(args['color'], 0xFF80DEEA);
      expect(args['bg'], 0x00000000);
      expect(args['outline'], isFalse);
      expect(args['delayMs'], -2000);
    });

    test('delay clamps to the supported window', () {
      expect(SubtitleStyle.minDelayMs, -30000);
      expect(SubtitleStyle.maxDelayMs, 30000);
      const style = SubtitleStyle(delayMs: 30000);
      expect(style.delaySeconds, 30.0);
    });
  });

  group('SubtitleSettingsScreen', () {
    testWidgets('renders preview and updates delay via slider', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: SubtitleSettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Sample subtitle line'), findsOneWidget);
      expect(find.text('Subtitles'), findsOneWidget); // app bar
      expect(find.text('Text size'), findsOneWidget);
      expect(find.text('Color'), findsOneWidget);
      expect(find.text('Background'), findsOneWidget);
      expect(find.text('Black outline'), findsOneWidget);

      // Drag the delay slider toward +30 s (scroll it into view first —
      // it sits below the fold). The screen now has three sliders
      // (background opacity, vertical position, delay) — find the delay
      // row by its Reset button context.
      final delayReset = find.widgetWithText(TextButton, 'Reset').last;
      await tester.scrollUntilVisible(
        delayReset,
        80,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      // The delay slider is the Slider immediately above the Reset row.
      final sliders = find.byType(Slider);
      // The delay slider is the LAST slider in the layout.
      final rect = tester.getRect(sliders.last);
      await tester.dragFrom(
        rect.centerLeft + const Offset(12, 0),
        Offset((rect.width - 24) * 0.8, 0),
      );
      await tester.pumpAndSettle();

      final loaded = await SubtitleStyle.load();
      expect(loaded.delayMs, greaterThan(0));

      // Reset returns it to zero. Tap the delay row's Reset (the last
      // one in the list).
      await tester.tap(delayReset);
      await tester.pumpAndSettle();
      expect((await SubtitleStyle.load()).delayMs, 0);
    });

    testWidgets('no overflow at small phone size with large text scale', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      await tester.pumpWidget(const MaterialApp(home: SubtitleSettingsScreen()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('landscape short viewport does not throw (clamp regression)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      // Landscape phone: 26% of 360 < the old 96px floor triggered
      // ArgumentError from clamp().
      tester.view.physicalSize = const Size(800, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: SubtitleSettingsScreen()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
