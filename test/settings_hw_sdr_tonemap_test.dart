import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/screens/settings_screen.dart';

/// The hardware SDR tone-mapping toggle (issue #55) drives the ANDROID video
/// codec (MediaCodec's `KEY_COLOR_TRANSFER_REQUEST`), so it must not appear
/// on iOS - where playback runs through AetherEngine and the setting would
/// resolve to nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap(Widget child) {
    return MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );
  }

  String toneMapTitle(WidgetTester tester) {
    return AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
        .settingsHwSdrToneMap;
  }

  String playerTitle(WidgetTester tester) {
    return AppLocalizations.of(tester.element(find.byType(SettingsScreen)))
        .settingsPlayer;
  }

  Future<void> openPlayerSection(WidgetTester tester) async {
    await tester.pumpAndSettle();
    final playerTile = find.text(playerTitle(tester));
    expect(playerTile, findsOneWidget);
    await tester.ensureVisible(playerTile);
    await tester.tap(playerTile);
    await tester.pumpAndSettle();
  }

  testWidgets('Settings hides hardware SDR tone-mapping on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await openPlayerSection(tester);

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text(toneMapTitle(tester)), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Settings shows hardware SDR tone-mapping on Android',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await openPlayerSection(tester);

    expect(find.text(toneMapTitle(tester)), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  group('issue #67: TextureView path paints the letterbox bars black', () {
    // The activity window is TRANSPARENT (Fire TV SurfaceView fix), and
    // setShutterBackgroundColor only paints the inner shutter - without a
    // background on the outer PlayerView, the letterbox bars around a
    // TextureView sink stay transparent and the screen behind bleeds through.
    test('the texture player-view layout has a black background', () {
      final xml = File(
        'android/app/src/main/res/layout/dream_texture_player_view.xml',
      ).readAsStringSync();
      expect(xml, contains('android:background="@android:color/black"'));
      expect(xml, contains('app:surface_type="texture_view"'));
    });

    test('the inflated texture view also sets a black background in code', () {
      final kt = File(
        'android/app/src/main/kotlin/com/dreamplayer/app/ExoPlayerView.kt',
      ).readAsStringSync();
      final at = kt.indexOf('R.layout.dream_texture_player_view');
      expect(at, greaterThan(-1));
      final block = kt.substring(at, at + 900);
      expect(block, contains('setBackgroundColor(android.graphics.Color.BLACK)'));
    });
  });
}
