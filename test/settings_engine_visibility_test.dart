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
///
/// Note the split across two sections, which is deliberate: Player holds the
/// engine-facing knobs (tone-map, decoder, spatial), Audio holds everything
/// that changes what comes out of the speakers.
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

  /// Expands a top-level settings section by its localised title.
  ///
  /// The settings screen is a lazy `ListView.builder`, so a section below the
  /// viewport has no widget in the tree at all and `find.text` cannot see it.
  /// Scroll first, then expand.
  Future<void> expandSection(WidgetTester tester, String Function(AppLocalizations) pick) async {
    await tester.pump(const Duration(milliseconds: 300));
    final tile = find.text(l(tester, pick));
    if (tile.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        tile,
        250,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  Future<void> pumpWithEngine(WidgetTester tester, DefaultEngine engine) async {
    // Tall but NARROW. Two traps here, both of which bite as a bare
    // "Bad state: No element" from the finder rather than a useful message:
    //
    //  * Height: with the Player section expanded the list is far taller than
    //    the default 800x600, and it is a lazy ListView.builder, so a section
    //    below the built range has no widget at all.
    //  * Width: `isTvMode` is `width >= 960dp`, and the Player section is
    //    hidden entirely in TV mode. Widening the surface to fit the content
    //    therefore made the very section under test disappear.
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({
      'flutter.dreamplayer.defaultEngine': engine.value,
    });
    await tester.pumpWidget(wrap());
    await expandSection(tester, (x) => x.settingsPlayer);
  }

  Future<void> openAudio(WidgetTester tester) =>
      expandSection(tester, (x) => x.settingsAudio);

  Finder engineTile(WidgetTester t) => find.text(l(t, (x) => x.settingsDefaultEngine));
  Finder decoderTile(WidgetTester t) => find.text(l(t, (x) => x.settingsVideoDecoder));
  Finder spatialTile(WidgetTester t) => find.text('Spatial audio');
  Finder toneMapTile(WidgetTester t) => find.text(l(t, (x) => x.settingsToneMapMode));
  Finder downmixTile(WidgetTester t) => find.text(l(t, (x) => x.settingsMpvNormalizeDownmix));
  Finder ffmpegAudioTile(WidgetTester t) => find.text('Match MPV audio (FFmpeg)');
  Finder volumeBoostTile(WidgetTester t) => find.text(l(t, (x) => x.settingsVolumeBoost));
  Finder nightModeTile(WidgetTester t) => find.text(l(t, (x) => x.settingsNightMode));

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

  testWidgets('pinning libmpv hides every Media3-only option in Player', (
    tester,
  ) async {
    await run(tester, () async {
      await pumpWithEngine(tester, DefaultEngine.mpv);
      expect(toneMapTile(tester), findsOneWidget);
      expect(decoderTile(tester), findsNothing);
      expect(spatialTile(tester), findsNothing);
    });
  });

  testWidgets('Audio: pinning Media3 hides the MPV-only downmix option', (
    tester,
  ) async {
    await run(tester, () async {
      await pumpWithEngine(tester, DefaultEngine.media3);
      await openAudio(tester);
      expect(downmixTile(tester), findsNothing);
      expect(ffmpegAudioTile(tester), findsOneWidget);
    });
  });

  testWidgets('Audio: pinning libmpv hides the Media3-only FFmpeg option', (
    tester,
  ) async {
    await run(tester, () async {
      await pumpWithEngine(tester, DefaultEngine.mpv);
      await openAudio(tester);
      expect(downmixTile(tester), findsOneWidget);
      expect(ffmpegAudioTile(tester), findsNothing);
    });
  });

  // One engine per test on purpose: a loop would reuse the same widget tree,
  // and the second iteration's `expandSection` would COLLAPSE the section the
  // first one opened, so the tiles would vanish for reasons unrelated to the
  // gating being tested.
  testWidgets('Volume Boost and Night Mode are offered with Media3 pinned', (
    tester,
  ) async {
    await run(tester, () async {
      await pumpWithEngine(tester, DefaultEngine.media3);
      await openAudio(tester);
      expect(volumeBoostTile(tester), findsOneWidget);
      expect(nightModeTile(tester), findsOneWidget);
    });
  });

  testWidgets('Volume Boost and Night Mode are offered with libmpv pinned', (
    tester,
  ) async {
    await run(tester, () async {
      await pumpWithEngine(tester, DefaultEngine.mpv);
      await openAudio(tester);
      expect(volumeBoostTile(tester), findsOneWidget);
      expect(nightModeTile(tester), findsOneWidget);
    });
  });

  testWidgets('Auto shows options for both engines', (tester) async {
    await run(tester, () async {
      await pumpWithEngine(tester, DefaultEngine.auto);
      expect(toneMapTile(tester), findsOneWidget);
      expect(decoderTile(tester), findsOneWidget);
      await openAudio(tester);
      expect(downmixTile(tester), findsOneWidget);
      expect(ffmpegAudioTile(tester), findsOneWidget);
    });
  });

  testWidgets('Ask every time shows options for both engines', (tester) async {
    await run(tester, () async {
      await pumpWithEngine(tester, DefaultEngine.ask);
      expect(toneMapTile(tester), findsOneWidget);
      expect(decoderTile(tester), findsOneWidget);
      await openAudio(tester);
      expect(downmixTile(tester), findsOneWidget);
      expect(ffmpegAudioTile(tester), findsOneWidget);
    });
  });
}
