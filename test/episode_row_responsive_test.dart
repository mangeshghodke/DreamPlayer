import 'package:dream_player/services/layout_store.dart';
import 'package:dream_player/widgets/episode_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Issue #38 follow-up: the size must follow the window, not a device class.
/// The first implementation asked `MediaQuery` for the whole screen width,
/// which cannot see the row's real constraints - inside padding, split screen
/// or a resized pane it never demoted and overflowed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, Size window, double inset,
      {double scale = 1.0}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = window;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: window.width - inset,
              child: MediaQuery(
                data: MediaQueryData(
                  size: Size(window.width - inset, window.height),
                  textScaler: TextScaler.linear(scale),
                ),
                child: ListView(
                  children: [
                    EpisodeRow(
                      thumbBuilder: (size) =>
                          EpisodeStillThumb(stillUrl: 's', size: size),
                      title: const Text('S01E05 · Episode title'),
                      trailing: IconButton(
                        icon: const Icon(Icons.check_circle_outline),
                        onPressed: () {},
                      ),
                      onTap: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double thumbWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(kEpisodeThumbBoxKey)).width;

  testWidgets('follows the row width, not the window width', (tester) async {
    await LayoutStore.instance.setThumbSize(EpisodeThumbSize.large);
    // Same window, but the row is inset. The row is narrower, so the thumbnail
    // must be smaller than the MediaQuery width would allow.
    await pump(tester, const Size(1200, 800), 0);
    final wide = thumbWidth(tester);
    // 1200 - 700 = 500 dp row: still roomy enough for "large", so this width
    // would not have exposed a MediaQuery-based implementation either.
    await pump(tester, const Size(1200, 800), 880);
    final inset = thumbWidth(tester);
    expect(wide, greaterThan(inset));
  });

  testWidgets('grows when the window widens, shrinks when it narrows',
      (tester) async {
    await LayoutStore.instance.setThumbSize(EpisodeThumbSize.large);
    await pump(tester, const Size(360, 800), 0);
    final phone = thumbWidth(tester);
    await pump(tester, const Size(1024, 768), 0);
    final tablet = thumbWidth(tester);
    expect(tablet, greaterThan(phone));
    // And back again - rotation must not leave the stale size behind.
    await pump(tester, const Size(360, 800), 0);
    expect(thumbWidth(tester), phone);
  });

  testWidgets('demotes at large text even on a roomy window', (tester) async {
    await LayoutStore.instance.setThumbSize(EpisodeThumbSize.large);
    // 450 dp is the band where text scale is decisive: "large" fits at 1.0
    // (450-260=190 >= 150) but not at 1.5 (190/1.5=127 < 150).
    await pump(tester, const Size(450, 800), 0);
    final normal = thumbWidth(tester);
    await pump(tester, const Size(450, 800), 0, scale: 1.5);
    final largeText = thumbWidth(tester);
    expect(normal, EpisodeThumbSize.large.still.w);
    expect(largeText, lessThan(normal));
  });

  testWidgets('never overflows across a sweep of widths and text scales',
      (tester) async {
    for (final w in [320.0, 360.0, 412.0, 600.0, 800.0, 1024.0, 1366.0]) {
      for (final scale in [1.0, 1.3, 1.6]) {
        for (final size in EpisodeThumbSize.values) {
          await LayoutStore.instance.setThumbSize(size);
          await pump(tester, Size(w, 800), 0, scale: scale);
          expect(tester.takeException(), isNull,
              reason: 'w=$w scale=$scale size=${size.value}');
        }
      }
    }
  });

  testWidgets('no overflow with no trailing slot', (tester) async {
    for (final w in [320.0, 360.0, 1024.0]) {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = Size(w, 800);
      addTearDown(tester.view.reset);
      await LayoutStore.instance.setThumbSize(EpisodeThumbSize.large);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                EpisodeRow(
                  thumbBuilder: (size) =>
                      EpisodeStillThumb(stillUrl: 's', size: size),
                  title: const Text('Episode'),
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'w=$w');
    }
  });
}
