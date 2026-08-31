import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/screens/player_screen.dart';
import 'package:dream_player/screens/tmd_details_screen.dart';
import 'package:dream_player/services/resume_store.dart';
import 'package:dream_player/services/tmdb_client.dart';

const _video = VideoItem(
  id: 'repro',
  title: 'Dolby Core Universe',
  path: '/storage/emulated/0/Download/video/Dolby-Core.mkv',
  duration: Duration(minutes: 136),
);

const _videoNoMatch = VideoItem(
  id: 'repro2',
  title: 'Some Unknown Movie',
  path: '/storage/emulated/0/Download/video/unknown.mkv',
  duration: Duration(minutes: 136),
);

const _episodeVideo = VideoItem(
  id: 'ep',
  title: 'House.S02E04.1080p.mkv',
  path: '/storage/emulated/0/Download/video/House/House.S02E04.mkv',
  duration: Duration(minutes: 44),
);

Future<void> _pumpAndCheck(
  WidgetTester tester,
  VideoItem video,
  Size physical, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = physical;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: TmdDetailsScreen(video: video),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    tester.takeException(),
    isNull,
    reason: 'overflow at ${physical.width}x${physical.height}@3'
        ' textScale=$textScale',
  );
}

void main() {
  testWidgets('matched state has no overflow at device sizes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await TmdStore.save(
      _video.path!,
      const TmdMeta(
        movie: TmdMovie(
          id: 1,
          title: 'Dolby Core Universe',
          year: 2024,
          overview: 'A very long overview that keeps going on and on and on '
              'and on and on and on and on and on and on and on and on.',
          voteAverage: 8.2,
          posterPath: '/poster.jpg',
          backdropPath: '/backdrop.jpg',
        ),
        details: TmdDetails(
          title: 'Dolby Core Universe',
          overview: 'A very long overview that keeps going on and on and on '
              'and on and on and on and on and on and on and on and on.',
          voteAverage: 8.2,
          voteCount: 10,
          year: 2024,
          runtimeMinutes: 136,
          genres: ['Action', 'Sci-Fi', 'Adventure', 'Thriller', 'Drama'],
          cast: [
            TmdCastMember(name: 'Actor One', character: 'Character'),
            TmdCastMember(name: 'Actor Two', character: 'Character'),
            TmdCastMember(name: 'Actor Three', character: 'Character'),
          ],
        ),
      ),
    );

    await _pumpAndCheck(tester, _video, const Size(1080, 2400)); // portrait
    await _pumpAndCheck(tester, _video, const Size(2400, 1080)); // landscape
    await _pumpAndCheck(
      tester,
      _video,
      const Size(2400, 1080),
      textScale: 1.3,
    );
  });

  testWidgets('no-match/error state has no overflow at device sizes', (
    tester,
  ) async {
    // A non-empty key makes TmdApi attempt real HTTP, which the test binding
  // blocks (HTTP 400), so the lookup throws exactly like a connection
  // problem on a device — exercising the SnackBar popup path.
    SharedPreferences.setMockInitialValues(
      const {'dreamplayer.tmdbApiKey': 'fake-key-for-test'},
    );
    // No metadata seeded: the lookup fails and the error no-match panel is
    // shown.
    await _pumpAndCheck(tester, _videoNoMatch, const Size(1080, 2400));
    await _pumpAndCheck(tester, _videoNoMatch, const Size(2400, 1080));

    // The failed lookup is signalled via a transient SnackBar popup…
    expect(find.textContaining('Check your connection'), findsOneWidget);

    // …while the no-match panel stays blank apart from the headline and the
    // Search TMDB button — no inline connection / API-key / metadata text.
    expect(find.textContaining('Could not find'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Search TMDB'),
      findsOneWidget,
    );
    expect(find.textContaining('API key'), findsNothing);
    expect(find.textContaining('metadata from TMDB'), findsNothing);
  });

  testWidgets('single-episode state has no overflow at device sizes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    // Seed a TV show whose season/episode data (cast, guest stars, stills)
    // exercises the single-episode sections: the images strip, the Episode
    // cast + Guest stars rows, and the Remove info/Fix match action wrap.
    const seedKey = 'seed:ep';
    await TmdStore.save(
      seedKey,
      TmdMeta(
        movie: TmdMovie(
          id: 456,
          title: 'House',
          kind: TmdKind.tv,
          year: 2004,
          posterPath: '/poster.jpg',
          backdropPath: '/backdrop.jpg',
        ),
        details: TmdDetails(
          title: 'House',
          overview: 'A very long show overview that keeps going on and on and '
              'on and on and on and on and on and on and on and on.',
          runtimeMinutes: 45,
          genres: ['Drama', 'Mystery'],
          numberOfSeasons: 8,
          numberOfEpisodes: 177,
        ),
        seasons: {
          2: TmdSeason(
            seasonNumber: 2,
            episodes: [
              TmdEpisode(
                episodeNumber: 4,
                name: 'Humble',
                overview: 'A very long episode overview that keeps going on '
                    'and on and on and on and on and on and on and on.',
                stillPath: '/stills/e4.jpg',
                airDate: '2005-11-01',
                runtimeMinutes: 44,
                voteAverage: 8.0,
                cast: [
                  TmdCastMember(name: 'Hugh Laurie', character: 'Dr. House'),
                  TmdCastMember(name: 'Lisa Edelstein', character: 'Cuddy'),
                  TmdCastMember(name: 'Omar Epps', character: 'Foreman'),
                ],
                guestStars: [
                  TmdCastMember(
                    name: 'David Morse',
                    character: 'Michael Tritter',
                  ),
                ],
                stills: [
                  '/stills/e4-1.jpg',
                  '/stills/e4-2.jpg',
                  '/stills/e4-3.jpg',
                ],
              ),
            ],
          ),
        },
      ),
    );
    await TmdService.instance.carryMeta(seedKey, _episodeVideo.path!);

    await _pumpAndCheck(tester, _episodeVideo, const Size(1080, 2400));
    await _pumpAndCheck(tester, _episodeVideo, const Size(2400, 1080));
    await _pumpAndCheck(
      tester,
      _episodeVideo,
      const Size(2400, 1080),
      textScale: 1.3,
    );
  });

  testWidgets('saved position shows both Resume and Watch from beginning '
      '(no overflow at device sizes)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await TmdStore.save(
      _video.path!,
      const TmdMeta(
        movie: TmdMovie(
          id: 1,
          title: 'Dolby Core Universe',
          year: 2024,
          overview: 'A short overview.',
          voteAverage: 8.2,
          posterPath: '/poster.jpg',
          backdropPath: '/backdrop.jpg',
        ),
      ),
    );
    // Resume key for `_video` is its path (no explicit resumeKey).
    await ResumeStore.save(_video.path!, const Duration(minutes: 12, seconds: 30), engine: 'media3');

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: TmdDetailsScreen(video: _video)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.widgetWithText(FilledButton, 'Resume from 12:30'),
      findsOneWidget,
    );
    // "Watch from beginning" is now an icon-only tonal button (the replay
    // glyph) next to the filled Resume button — no text label.
    expect(find.byIcon(Icons.replay), findsOneWidget);
    expect(find.text('Watch from beginning'), findsNothing);

    // Tapping the replay button must push the player with the
    // startFromBeginning flag instead of resuming.
    await tester.tap(find.byIcon(Icons.replay));
    await tester.pumpAndSettle();
    final screen = tester.widget<PlayerScreen>(
      find.byType(PlayerScreen),
    );
    expect(screen.startFromBeginning, isTrue);
    addTearDown(() async {
      // Return to the details screen state after the incidental player push.
      tester.pumpWidget(const SizedBox());
    });
  });
}
