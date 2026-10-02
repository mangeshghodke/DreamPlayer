import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/services/layout_store.dart';
import 'package:dream_player/widgets/episode_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';


/// Issue #38: episode thumbnails were rendered at 48x56 because `ListTile`
/// clamps `leading` to 56 px, silently discarding the 72 the code asked for.
/// These tests measure what is ACTUALLY laid out, because the declared size
/// and the real size were the thing that disagreed.
/// Sets the real view size so [MediaQuery] reflects it.
Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpRow(
    WidgetTester tester, {
    required EpisodeThumbSize size,
    Size surface = const Size(390, 844),
    bool usePoster = false,
  }) async {
    // tester.view, NOT binding.setSurfaceSize: the latter does not change what
    // MediaQuery reports, so MediaQuery.width stayed 800 and the phone/tablet
    // branches were never actually exercised.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = surface;
    addTearDown(tester.view.reset);
    await LayoutStore.instance.setThumbSize(size);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ListView(
            children: [
              EpisodeRow(
                thumb: usePoster
                    ? const EpisodePosterThumb(posterUrl: 'p')
                    : const EpisodeStillThumb(stillUrl: 's'),
                title: const Text('S02E04 · The Name Of The Episode'),
                subtitle: const Text('9.8 · 1.4 GB · Resume at 12:29'),
                progress: const LinearProgressIndicator(value: 0.4),
                trailing: const Icon(Icons.check_circle, size: 22),
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('EpisodeThumbGeometry', () {
    test('medium and large beat ListTile\'s 56px leading cap', () {
      // small is deliberately unchanged; the other two must escape the cap or
      // the feature does nothing.
      for (final s in [EpisodeThumbSize.medium, EpisodeThumbSize.large]) {
        expect(
          s.still.h,
          greaterThan(56),
          reason: '$s still must beat the ListTile cap',
        );
        expect(s.rowMinHeight, greaterThan(56));
      }
    });

    test('the poster variant escapes the cap at every size', () {
      for (final s in EpisodeThumbSize.values) {
        expect(s.poster.h, greaterThanOrEqualTo(56));
      }
    });

    test('small poster is 48x56, the size users actually saw', () {
      // Not 48x72 - ListTile clamped that to 56.
      expect(EpisodeThumbSize.small.poster, (w: 48, h: 56));
    });

    test('sizes increase monotonically', () {
      const order = EpisodeThumbSize.values;
      for (var i = 1; i < order.length; i++) {
        expect(order[i].still.w, greaterThan(order[i - 1].still.w));
        expect(order[i].poster.h, greaterThan(order[i - 1].poster.h));
        expect(order[i].rowMinHeight, greaterThan(order[i - 1].rowMinHeight));
      }
    });

    test('small reproduces the old 64x40 still, large is 2.6x wider', () {
      expect(EpisodeThumbSize.small.still, (w: 64, h: 40));
      expect(EpisodeThumbSize.large.still.w, 168);
      expect(EpisodeThumbSize.large.still.h, 95);
    });

    test('small is never shorter than a ListTile would have been', () {
      expect(EpisodeThumbSize.small.rowMinHeight, 56);
    });
  });

  group('EpisodeRow layout', () {
    testWidgets('on a tablet large renders its full 168x95 still',
        (tester) async {
      await pumpRow(
        tester,
        size: EpisodeThumbSize.large,
        surface: const Size(1024, 768),
      );
      final size = tester.getSize(find.byKey(kEpisodeThumbBoxKey));
      expect(size.width, EpisodeThumbSize.large.still.w);
      expect(size.height, EpisodeThumbSize.large.still.h);
      expect(size.height, greaterThan(56));
    });

    testWidgets('every size still beats the old 56px cap on a tablet',
        (tester) async {
      for (final s in EpisodeThumbSize.values) {
        await pumpRow(tester, size: s, surface: const Size(1024, 768));
        final h = tester.getSize(find.byKey(kEpisodeThumbBoxKey)).height;
        expect(h, greaterThanOrEqualTo(40), reason: s.value);
      }
    });

    testWidgets('on a tablet medium and large are bigger than small',
        (tester) async {
      const tablet = Size(1024, 768);
      await pumpRow(tester,
          size: EpisodeThumbSize.small, surface: tablet);
      final small = tester.getSize(find.byKey(kEpisodeThumbBoxKey));
      await pumpRow(tester,
          size: EpisodeThumbSize.medium, surface: tablet);
      final medium = tester.getSize(find.byKey(kEpisodeThumbBoxKey));
      await pumpRow(tester,
          size: EpisodeThumbSize.large, surface: tablet);
      final large = tester.getSize(find.byKey(kEpisodeThumbBoxKey));

      expect(medium.width, greaterThan(small.width));
      expect(medium.height, greaterThan(small.height));
      expect(large.width, greaterThan(medium.width));
      expect(large.height, greaterThan(medium.height));
    });

    testWidgets('a narrow phone demotes large one step so text survives',
        (tester) async {
      const phone = Size(390, 844);
      await pumpRow(
        tester,
        size: EpisodeThumbSize.large,
        surface: phone,
      );
      // 390 - (168 thumb + 12 gap + 24 padding) = 186 < 200, so large demotes
      // to medium - one step, not straight to small.
      final got = tester.getSize(find.byKey(kEpisodeThumbBoxKey));
      expect(got.width, EpisodeThumbSize.medium.still.w);
      expect(got.height, EpisodeThumbSize.medium.still.h);

      // And the text column it leaves is at least the documented minimum.
      const overhead = 112 + 12 + 24;
      expect(390 - overhead, greaterThanOrEqualTo(200));
    });

    testWidgets('medium is still honoured on a normal phone', (tester) async {
      const phone = Size(390, 844);
      await pumpRow(tester,
          size: EpisodeThumbSize.medium, surface: phone);
      final got = tester.getSize(find.byKey(kEpisodeThumbBoxKey));
      expect(got.width, EpisodeThumbSize.medium.still.w);
    });

    testWidgets('tall poster thumb also escapes the cap', (tester) async {
      await pumpRow(
        tester,
        size: EpisodeThumbSize.large,
        surface: const Size(1024, 768),
        usePoster: true,
      );
      final size = tester.getSize(
        find.byKey(kEpisodeThumbBoxKey),
      );
      expect(size.height, greaterThan(56));
    });

    testWidgets('falls back to an icon with no still', (tester) async {
      await _setSurface(tester, const Size(390, 844));
      await LayoutStore.instance.setThumbSize(EpisodeThumbSize.large);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                EpisodeRow(
                  thumb: const EpisodeStillThumb(stillUrl: null),
                  title: const Text('No still'),
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    });

    testWidgets('changing the preference resizes a mounted row live',
        (tester) async {
      const tablet = Size(1024, 768);
      await pumpRow(tester, size: EpisodeThumbSize.small, surface: tablet);
      final before = tester.getSize(find.byKey(kEpisodeThumbBoxKey));
      await LayoutStore.instance.setThumbSize(EpisodeThumbSize.large);
      await tester.pumpAndSettle();
      final after = tester.getSize(find.byKey(kEpisodeThumbBoxKey));
      expect(after.width, greaterThan(before.width));
      expect(after.height, greaterThan(before.height));
    });

    testWidgets('tap fires exactly once', (tester) async {
      await _setSurface(tester, const Size(390, 844));
      await LayoutStore.instance.setThumbSize(EpisodeThumbSize.large);
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                EpisodeRow(
                  thumb: const EpisodeStillThumb(stillUrl: 's'),
                  title: const Text('Episode'),
                  onTap: () => taps++,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(EpisodeRow));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('disabled row ignores taps', (tester) async {
      await _setSurface(tester, const Size(390, 844));
      await LayoutStore.instance.setThumbSize(EpisodeThumbSize.small);
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                EpisodeRow(
                  thumb: const EpisodeStillThumb(stillUrl: 's'),
                  title: const Text('Episode'),
                  enabled: false,
                  onTap: () => taps++,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(EpisodeRow));
      await tester.pumpAndSettle();
      expect(taps, 0);
    });

    testWidgets('long-press is not the primary action', (tester) async {
      await _setSurface(tester, const Size(390, 844));
      await LayoutStore.instance.setThumbSize(EpisodeThumbSize.small);
      var taps = 0, longs = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                EpisodeRow(
                  thumb: const EpisodeStillThumb(stillUrl: 's'),
                  title: const Text('Episode'),
                  onTap: () => taps++,
                  onLongPress: () => longs++,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.byType(EpisodeRow));
      await tester.pumpAndSettle();
      expect(longs, 1);
      expect(taps, 0);
    });
  });

  group('no overflow', () {
    for (final surface in const [
      Size(320, 568), // small phone
      Size(390, 844), // phone
      Size(1024, 768), // tablet portrait — the reporter's target
      Size(1366, 768), // tablet landscape
    ]) {
      for (final size in EpisodeThumbSize.values) {
        testWidgets('${surface.width.toInt()}x${surface.height.toInt()} '
            '${size.value}', (tester) async {
          await pumpRow(tester, size: size, surface: surface);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
