import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/settings_screen.dart';
import 'package:dream_player/services/default_engine_store.dart';

/// Engine-specific settings must only appear when the engine they belong to can
/// actually run.
///
/// "Auto" and "Ask every time" can both land on either engine, so everything
/// stays visible there. Pinning an engine in Player -> Default playback engine
/// makes the other engine's knobs dead settings, so they are hidden.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  /// Runs [body], then clears `debugDefaultTargetPlatformOverride` BEFORE the
  /// test function returns.
  ///
  /// A `tearDown` is too late: the binding verifies foundation invariants
  /// before tearDown runs, so an override still set at that point fails every
  /// test with "The value of a foundation debug variable was changed by the
  /// test". Same trap as settings_tone_map_platform_test.dart.
  Future<void> run(WidgetTester tester, Future<void> Function() body) async {
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Widget wrap() => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const Scaffold(body: SettingsScreen()),
  );

  String l(WidgetTester t, String Function(AppLocalizations) pick) =>
      pick(AppLocalizations.of(t.element(find.byType(SettingsScreen))));

  Future<void> pumpWithEngine(WidgetTester tester, DefaultEngine engine) async {
    SharedPreferences.setMockInitialValues({
      'flutter.dreamplayer.defaultEngine': engine.value,
    });
    await tester.pumpWidget(wrap());
    await tester.pump(const Duration(milliseconds: 300));
    final tile = find.text(l(tester, (x) => x.settingsPlayer));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  Finder engineTile(WidgetTester t) =>
      find.text(l(t, (x) => x.settingsDefaultEngine));
  Finder decoderTile(WidgetTester t) =>
      find.text(l(t, (x) => x.settingsVideoDecoder));
  Finder spatialTile(WidgetTester t) => find.text('Spatial audio');
  Finder toneMapTile(WidgetTester t) =>
      find.text(l(t, (x) => x.settingsToneMapMode));
  Finder ffmpegAudioTile(WidgetTester t) =>
      find.text('Match MPV audio (FFmpeg)');

  testWidgets('pinning Media3 hides the MPV-only tone-map option', (
    tester,
  ) async {
    await run(tester, () async {
      await pumpWithEngine(tester, DefaultEngine.media3);
      expect(engineTile(tester), findsOneWidget);
      expect(decoderTile(tester), findsOneWidget);
      expect(toneMapTile(tester), findsNothing);
    });
  });

  testWidgets('pinning Media3 keeps the Media3-only options', (tester) async {
    await run(tester, () async {
      await pumpWithEngine(tester, DefaultEngine.media3);
      expect(ffmpegAudioTile(tester), findsOneWidget);
      expect(spatialTile(tester), findsOneWidget);
    });
  });

  testWidgets('pinning libmpv hides every Media3-only option', (tester) async {
    await run(tester, () async {
      await pumpWithEngine(tester, DefaultEngine.mpv);
      expect(toneMapTile(tester), findsOneWidget);
      expect(decoderTile(tester), findsNothing);
      expect(ffmpegAudioTile(tester), findsNothing);
      expect(spatialTile(tester), findsNothing);
    });
  });

  testWidgets('Ask every time shows options for both engines', (tester) async {
    await run(tester, () async {
      await pumpWithEngine(tester, DefaultEngine.ask);
      expect(toneMapTile(tester), findsOneWidget);
      expect(decoderTile(tester), findsOneWidget);
      expect(ffmpegAudioTile(tester), findsOneWidget);
      expect(spatialTile(tester), findsOneWidget);
    });
  });

  testWidgets('Auto shows options for both engines', (tester) async {
    await run(tester, () async {
      await pumpWithEngine(tester, DefaultEngine.auto);
      expect(toneMapTile(tester), findsOneWidget);
      expect(decoderTile(tester), findsOneWidget);
      expect(ffmpegAudioTile(tester), findsOneWidget);
    });
  });
}
