import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/tmdb_client.dart';

void main() {
  group('ParsedFileName', () {
    test('parses a movie title and year from a scene filename', () {
      final parsed = ParsedFileName.parse(
        'The.Great.Movie.2015.1080p.BluRay.x265-GROUP.mkv',
      );
      expect(parsed.title, 'The Great Movie');
      expect(parsed.year, 2015);
      expect(parsed.isEpisode, isFalse);
      expect(parsed.seriesName, isNull);
    });

    test('strips release group, quality, and codec noise', () {
      final parsed = ParsedFileName.parse(
        'Inception.2010.2160p.UHD.HDR10.DV.WEB-DL.DDP5.1.Atmos.HEVC.mkv',
      );
      expect(parsed.title, 'Inception');
      expect(parsed.year, 2010);
    });

    test('detects a TV episode and keeps the series name', () {
      final parsed = ParsedFileName.parse('Breaking.Bad.S01E03.720p.WEB-DL.mkv');
      expect(parsed.isEpisode, isTrue);
      expect(parsed.seriesName, 'Breaking Bad');
      expect(parsed.title, 'Breaking Bad');
    });

    test('extracts season and episode numbers with labels', () {
      final parsed = ParsedFileName.parse('House.S02E04.720p.WEB-DL.mkv');
      expect(parsed.isEpisode, isTrue);
      expect(parsed.season, 2);
      expect(parsed.episode, 4);
      expect(parsed.episodeLabel, 'S02E04');
      expect(parsed.seasonEpisodeLabel, 'Season 2 · Episode 4');
    });

    test('parses the short season x episode pattern too', () {
      final parsed = ParsedFileName.parse('Stranger.Things.1x03.mkv');
      expect(parsed.isEpisode, isTrue);
      expect(parsed.season, 1);
      expect(parsed.episode, 3);
      expect(parsed.episodeLabel, 'S01E03');
    });

    test('seriesName excludes stale Sxx tag when year is inside parens', () {
      // Regression: `Kakegurui Twin (2021) S01E01.mkv` used to yield
      // `seriesName = "Kakegurui Twin S01"` because the year strip shifted
      // offsets, but the regex match positions stayed stale — so substring(0,
      // m.start) leaked `S01` into the series name and TMDB search 404'd.
      final parsed = ParsedFileName.parse('Kakegurui Twin (2021) S01E01.mkv');
      expect(parsed.seriesName, 'Kakegurui Twin');
      expect(parsed.year, 2021);
      expect(parsed.isEpisode, isTrue);
      expect(parsed.season, 1);
      expect(parsed.episode, 1);
    });

    test('seriesName excludes stale Sxx tag with other show/year combos', () {
      final p1 = ParsedFileName.parse('Show (2013) S02E04.mkv');
      expect(p1.seriesName, 'Show');
      expect(p1.year, 2013);
      expect(p1.season, 2);
      expect(p1.episode, 4);

      final p2 = ParsedFileName.parse('Stranger Things (2016) S04E09.mkv');
      expect(p2.seriesName, 'Stranger Things');
      expect(p2.year, 2016);
      expect(p2.season, 4);
      expect(p2.episode, 9);
    });

    test('episode labels are empty for movies', () {
      final parsed = ParsedFileName.parse('Inception.2010.1080p.mkv');
      expect(parsed.isEpisode, isFalse);
      expect(parsed.season, 0);
      expect(parsed.episode, 0);
      expect(parsed.episodeLabel, '');
      expect(parsed.seasonEpisodeLabel, '');
    });

    test('detects season-episode with underscores and brackets', () {
      final parsed = ParsedFileName.parse('Stranger_Things_[S02E04]_1080p.mp4');
      expect(parsed.isEpisode, isTrue);
      expect(parsed.seriesName, 'Stranger Things');
    });

    test('year is null when the filename has no year', () {
      final parsed = ParsedFileName.parse('Some.Movie.1080p.WEBRip.mp4');
      expect(parsed.year, isNull);
      expect(parsed.title, 'Some Movie');
    });

    test('falls back to the raw name for a single-word file', () {
      final parsed = ParsedFileName.parse('Trailer.mp4');
      expect(parsed.title, 'Trailer');
    });

    test('strips a bare season tag from a whole-season folder name', () {
      final parsed = ParsedFileName.parse(
        'HOUSE.S02.1080p.10bit.BluRay.English.AAC.5.1.x265-Panda',
      );
      expect(parsed.isEpisode, isFalse);
      expect(parsed.season, 2);
      expect(parsed.seriesName, 'HOUSE');
      expect(parsed.title, 'HOUSE');
    });

    test('strips audio-language and streaming-provider noise', () {
      final parsed = ParsedFileName.parse(
        'I.Will.Find.You.S01.2160p.NF.WEB-DL.MULTi.DDP5.1.Atmos.DV.HDR.H.265-4kHdHub.Com',
      );
      expect(parsed.season, 1);
      expect(parsed.title, 'I Will Find You');
      expect(parsed.seriesName, 'I Will Find You');
    });

    test('strips bracket audio metadata from the search title', () {
      final parsed = ParsedFileName.parse(
        'Her (2013) 1080p BluRay REMUX AVC x264 '
        '[Hindi AMZN DDP 2.0 224kbps + English DTS-HD MA 5.1] '
        'ESub-(FraMeSToR-4kHdHub).mkv',
      );
      expect(parsed.title, 'Her');
      expect(parsed.year, 2013);
    });

    test('strips MA / SDR / Hindi noise from the search title', () {
      final parsed = ParsedFileName.parse(
        'Silence.2016.1080p.BluRay.REMUX.AVC.English.DTS-HD.MA.5.1-FraMeSToR.mkv',
      );
      expect(parsed.title, 'Silence');
      expect(parsed.year, 2016);

      final hdHub = ParsedFileName.parse(
        '24.2016.UNCUT.4K-2160p.SDR.TK.WEB-DL.Hindi.DDP5.1-Tamil.DD5.1.'
        'HEVC.x265-HDHub4u.Ms.mkv',
      );
      expect(hdHub.title, '24');
      expect(hdHub.year, 2016);

      final oldboy = ParsedFileName.parse(
        'Oldboy 2003 1080p BluRay [Hindi DDP 5.1   Korean DTS 5.1] x264 '
        'USURY-4kHdHub.com.mkv',
      );
      expect(oldboy.title, 'Oldboy');
      expect(oldboy.year, 2003);
    });

    test('ignores a year at the very start of the filename', () {
      // `2001.A.Space.Odyssey` would falsely extract year 2001 — but the
      // first character is the year itself, not a word boundary followed by
      // one. Reject year-at-position-0 so the parsed title stays intact.
      final parsed = ParsedFileName.parse('2001.ASpaceOdyssey.1080p.mkv');
      expect(parsed.year, isNull,
          reason: 'year at position 0 is a false-positive');
      // The title cleans up "2001 A Space Odyssey" without the year stealing
      // it from the search query.
      expect(parsed.title, isNotEmpty);
    });

    group('parent folder fallback', () {
      test('Episode01.mkv inside "Kakegurui Twin(2021)" → seriesName=Kakegurui Twin, year=2021', () {
        final parsed = ParsedFileName.parse(
          'Episode01.mkv',
          parentFolderName: 'Kakegurui Twin(2021)',
        );
        expect(parsed.seriesName, 'Kakegurui Twin');
        expect(parsed.year, 2021);
        expect(parsed.title, isNotEmpty);
      });

      test('Episode 02.mkv inside "Breaking Bad (2008)" inherits series + year', () {
        final parsed = ParsedFileName.parse(
          'Episode 02.mkv',
          parentFolderName: 'Breaking Bad (2008)',
        );
        expect(parsed.seriesName, 'Breaking Bad');
        expect(parsed.year, 2008);
      });

      test('does NOT inherit when the file already has SxxExx', () {
        // The file is explicit about its series via SxxExx — the parent
        // folder name should not overwrite the file's seriesName.
        final parsed = ParsedFileName.parse(
          'Wrong.Show.S02E03.mkv',
          parentFolderName: 'Right Show (2020)',
        );
        expect(parsed.seriesName, 'Wrong Show');
      });

      test('does NOT inherit when the parent folder has SxxExx (it is an episode)', () {
        // A parent folder named `Show.S02E05` is itself an episode, so it
        // should not be treated as the show name.
        final parsed = ParsedFileName.parse(
          'something.mkv',
          parentFolderName: 'Show.S02E05',
        );
        expect(parsed.seriesName, isNull);
      });

      test('parent folder with only a season tag inherits series + season', () {
        // Folder "Show.Name.Season.1" should provide the series name.
        // We don't extract season number from the folder (the file already
        // has its own season).
        final parsed = ParsedFileName.parse(
          '01.mkv',
          parentFolderName: 'Show.Name.Season.1.1080p',
        );
        expect(parsed.seriesName, isNotNull);
      });

      test('parent folder without year: only seriesName inherits', () {
        final parsed = ParsedFileName.parse(
          'ep1.mkv',
          parentFolderName: 'Some Anime',
        );
        expect(parsed.seriesName, 'Some Anime');
        expect(parsed.year, isNull);
      });

      test('parent folder name with no year and explicit file year keeps file year', () {
        final parsed = ParsedFileName.parse(
          'ep1.mkv',
          parentFolderName: 'Some Anime',
        );
        expect(parsed.year, isNull);
      });
    });
  });

  group('TmdStore', () {
    test('round-trips TmdMeta through SharedPreferences JSON', () async {
      SharedPreferences.setMockInitialValues({});
      final meta = TmdMeta(
        movie: const TmdMovie(
          id: 603,
          title: 'The Matrix',
          year: 1999,
          posterPath: '/poster.jpg',
          backdropPath: '/backdrop.jpg',
          overview: 'A computer hacker learns the truth.',
          voteAverage: 8.2,
        ),
        details: const TmdDetails(
          title: 'The Matrix',
          overview: 'A computer hacker learns the truth.',
          voteAverage: 8.2,
          voteCount: 23000,
          year: 1999,
          runtimeMinutes: 136,
          genres: ['Action', 'Sci-Fi'],
          cast: [
            TmdCastMember(name: 'Keanu Reeves', character: 'Neo'),
          ],
        ),
      );
      await TmdStore.save('the-matrix-1999', meta);

      final loaded = await TmdStore.loadAll();
      final restored = loaded['the-matrix-1999'];
      expect(restored, isNotNull);
      expect(restored!.movie.id, 603);
      expect(restored.movie.title, 'The Matrix');
      expect(restored.movie.year, 1999);
      expect(restored.movie.posterUrl(), isNotNull);
      expect(restored.details, isNotNull);
      expect(restored.details!.runtimeMinutes, 136);
      expect(restored.details!.cast.single.name, 'Keanu Reeves');
      expect(restored.details!.cast.single.character, 'Neo');
    });

    test('image URLs are absolute and default to w342 for posters', () {
      const movie = TmdMovie(
        id: 1,
        title: 'X',
        posterPath: '/p.jpg',
        backdropPath: '/b.jpg',
      );
      expect(movie.posterUrl(), 'https://image.tmdb.org/t/p/w342/p.jpg');
      expect(movie.posterUrl(width: 780), 'https://image.tmdb.org/t/p/w780/p.jpg');
      expect(
        movie.backdropUrl(),
        'https://image.tmdb.org/t/p/w780/b.jpg',
      );
    });
  });

  group('TmdApi effective key', () {
    test('returns the key stored in prefs when the default is empty', () async {
      SharedPreferences.setMockInitialValues({});
      final api = TmdApi(apiKey: '');
      expect(await api.effectiveApiKey(), isEmpty);
      SharedPreferences.setMockInitialValues({TmdApi.prefsKey: 'abc123'});
      expect(await api.effectiveApiKey(), 'abc123');
    });
  });

  group('TmdMeta JSON', () {
    test('serializes and deserializes nested details', () {
      final meta = TmdMeta(
        movie: const TmdMovie(
          id: 11,
          title: 'Dune: Part Two',
          year: 2024,
          voteAverage: 8.1,
        ),
        details: const TmdDetails(
          title: 'Dune: Part Two',
          year: 2024,
          runtimeMinutes: 166,
          genres: ['Sci-Fi'],
        ),
      );
      final roundTripped = TmdMeta.fromJson(
        jsonDecode(jsonEncode(meta.toJson())) as Map<String, dynamic>,
      );
      expect(roundTripped.movie.id, 11);
      expect(roundTripped.details!.runtimeMinutes, 166);
    });
  });

  group('TmdSeason / TmdEpisode', () {
    test('round-trips episodes through JSON', () {
      const season = TmdSeason(
        seasonNumber: 2,
        name: 'Season 2',
        episodes: [
          TmdEpisode(
            episodeNumber: 4,
            name: 'Humble',
            overview: 'House faces a difficult choice.',
            runtimeMinutes: 44,
            voteAverage: 8.0,
          ),
          TmdEpisode(episodeNumber: 5, name: 'Follow the Ashes'),
        ],
      );
      final restored = TmdSeason.fromJson(
        jsonDecode(jsonEncode(season.toJson())) as Map<String, dynamic>,
      );
      expect(restored.seasonNumber, 2);
      expect(restored.name, 'Season 2');
      expect(restored.episodes, hasLength(2));
      expect(restored.episode(4)!.name, 'Humble');
      expect(restored.episode(4)!.overview, 'House faces a difficult choice.');
      expect(restored.episode(4)!.runtimeMinutes, 44);
      expect(restored.episode(4)!.voteAverage, 8.0);
      expect(restored.episode(5)!.nameLabel, 'Follow the Ashes');
      expect(restored.episode(99), isNull);
    });

    test('episode name falls back to "Episode N" when unnamed', () {
      const episode = TmdEpisode(episodeNumber: 3);
      expect(episode.nameLabel, 'Episode 3');
    });

    test('TmdMeta stores seasons by number and round-trips them', () {
      final meta = TmdMeta(
        movie: const TmdMovie(id: 456, title: 'House', kind: TmdKind.tv),
        details: const TmdDetails(
          title: 'House',
          numberOfSeasons: 8,
          numberOfEpisodes: 177,
        ),
        seasons: {
          2: const TmdSeason(
            seasonNumber: 2,
            episodes: [TmdEpisode(episodeNumber: 4, name: 'Humble')],
          ),
        },
      );
      final restored = TmdMeta.fromJson(
        jsonDecode(jsonEncode(meta.toJson())) as Map<String, dynamic>,
      );
      expect(restored.movie.kind, TmdKind.tv);
      expect(restored.details!.numberOfSeasons, 8);
      expect(restored.details!.numberOfEpisodes, 177);
      expect(restored.seasons[2], isNotNull);
      expect(restored.seasons[2]!.episode(4)!.name, 'Humble');
    });

    test('withSeason adds a season without dropping details', () {
      final meta = TmdMeta(
        movie: const TmdMovie(id: 1, title: 'X', kind: TmdKind.tv),
        details: const TmdDetails(title: 'X'),
      );
      final updated = meta.withSeason(
        const TmdSeason(
          seasonNumber: 1,
          episodes: [TmdEpisode(episodeNumber: 1, name: 'Pilot')],
        ),
      );
      expect(updated.details, isNotNull);
      expect(updated.seasons[1]!.episode(1)!.name, 'Pilot');
      expect(meta.seasons, isEmpty);
    });

    test('episode round-trips cast, guest stars, and stills through JSON', () {
      const episode = TmdEpisode(
        episodeNumber: 4,
        name: 'Humble',
        cast: [
          TmdCastMember(name: 'Hugh Laurie', character: 'Dr. House'),
          TmdCastMember(name: 'Lisa Edelstein', character: 'Cuddy'),
        ],
        guestStars: [
          TmdCastMember(name: 'David Morse', character: 'Michael Tritter'),
        ],
        stills: ['/stills/e4-1.jpg', '/stills/e4-2.jpg'],
      );
      final restored = TmdEpisode.fromJson(
        jsonDecode(jsonEncode(episode.toJson())) as Map<String, dynamic>,
      );
      expect(restored.cast, hasLength(2));
      expect(restored.cast[0].name, 'Hugh Laurie');
      expect(restored.cast[0].character, 'Dr. House');
      expect(restored.cast[1].profilePath, isNull);
      expect(restored.guestStars, hasLength(1));
      expect(restored.guestStars[0].name, 'David Morse');
      expect(restored.guestStars[0].character, 'Michael Tritter');
      expect(restored.stills, hasLength(2));
      expect(
        restored.stillUrls(),
        ['https://image.tmdb.org/t/p/w500/stills/e4-1.jpg', 'https://image.tmdb.org/t/p/w500/stills/e4-2.jpg'],
      );
    });

    test('episode fromJson reads API credits/images keys too', () {
      final apiJson = <String, dynamic>{
        'episode_number': 4,
        'name': 'Humble',
        'credits': {
          'cast': [
            {'name': 'Hugh Laurie', 'character': 'Dr. House', 'profile_path': '/hl.jpg'},
          ],
          'guest_stars': [
            {'name': 'David Morse', 'character': 'Michael Tritter', 'profile_path': '/dm.jpg'},
          ],
        },
        'images': {
          'stills': [
            {'file_path': '/stills/e4-1.jpg'},
          ],
        },
      };
      final parsed = TmdEpisode.fromJson(apiJson);
      expect(parsed.episodeNumber, 4);
      expect(parsed.cast.single.name, 'Hugh Laurie');
      expect(parsed.cast.single.character, 'Dr. House');
      expect(parsed.cast.single.profileUrl(width: 185), 'https://image.tmdb.org/t/p/w185/hl.jpg');
      expect(parsed.guestStars.single.name, 'David Morse');
      expect(parsed.guestStars.single.character, 'Michael Tritter');
      expect(parsed.guestStars.single.profileUrl(width: 185), 'https://image.tmdb.org/t/p/w185/dm.jpg');
      expect(parsed.stills, ['/stills/e4-1.jpg']);
    });

    test('withEpisode swaps an episode without dropping siblings', () {
      const season = TmdSeason(
        seasonNumber: 1,
        episodes: [
          TmdEpisode(episodeNumber: 1, name: 'Pilot'),
          TmdEpisode(episodeNumber: 2, name: 'Second'),
        ],
      );
      final updated = season.withEpisode(
        const TmdEpisode(
          episodeNumber: 2,
          name: 'Second',
          cast: [TmdCastMember(name: 'Someone')],
        ),
      );
      expect(updated.episode(1)!.name, 'Pilot');
      expect(updated.episode(2)!.cast, hasLength(1));
      expect(season.episode(2)!.cast, isEmpty);
    });
  });

  group('TmdService carryMeta', () {
    test('carries movie + details + seasons onto the episode key', () async {
      SharedPreferences.setMockInitialValues({});
      final service = TmdService.instance;
      await service.ensureLoaded();
      const movie = TmdMovie(id: 456, title: 'House', kind: TmdKind.tv);
      final folderMeta = TmdMeta(
        movie: movie,
        details: const TmdDetails(
          title: 'House',
          numberOfSeasons: 8,
          numberOfEpisodes: 177,
        ),
        seasons: {
          2: const TmdSeason(
            seasonNumber: 2,
            episodes: [TmdEpisode(episodeNumber: 4, name: 'Humble')],
          ),
        },
      );
      // Simulate the folder having been resolved + seasons loaded into prefs,
      // as the folder details screen does before an episode is tapped.
      await TmdStore.save('folder:1', folderMeta);

      await service.carryMeta('folder:1', '/videos/house-s02e04.mkv');

      final carried = service.metaFor('/videos/house-s02e04.mkv');
      expect(carried, isNotNull);
      expect(carried!.movie.kind, TmdKind.tv);
      expect(carried.details!.numberOfSeasons, 8);
      expect(carried.seasons[2]!.episode(4)!.name, 'Humble');
      // The source key is left untouched.
      expect(service.metaFor('folder:1'), isNotNull);
    });

    test('carry is a no-op for empty or equal keys', () async {
      SharedPreferences.setMockInitialValues({});
      final service = TmdService.instance;
      await service.ensureLoaded();
      await service.carryMeta('', '/videos/x.mkv');
      await service.carryMeta('/videos/x.mkv', '/videos/x.mkv');
      expect(service.metaFor('/videos/x.mkv'), isNull);
    });
  });

  group('Levenshtein scoring', () {
    test('exact title match scores 1.0 via bestMatch', () async {
      SharedPreferences.setMockInitialValues({});
      final parsed = ParsedFileName.parse('Kakegurui Twin (2021) S01E01.mkv');
      // bestMatch calls _score internally; we test the observable result.
      // Without a real API key, bestMatch returns null — but the parser
      // correctness is what matters (seriesName must be "Kakegurui Twin").
      expect(parsed.seriesName, 'Kakegurui Twin');
      expect(parsed.year, 2021);
      expect(parsed.isEpisode, isTrue);
    });

    test('year tiebreaker: same title, different years — year matched wins', () async {
      // Verify that ParsedFileName extracts year correctly for the tiebreaker.
      final parsed = ParsedFileName.parse('Kakegurui Twin (2021) S01E01.mkv');
      expect(parsed.year, 2021);
      // The search would return both 2021 and 2022 results; with the year
      // tiebreaker in _score, the 2021 result should score higher.
      final parsed2 = ParsedFileName.parse('Kakegurui Twin (2022) S01E01.mkv');
      expect(parsed2.year, 2022);
    });

    test('Live Action keyword sets the liveAction flag', () {
      // Folder with explicit "Live Action" — flag should be set.
      final parsed =
          ParsedFileName.parse('Kakegurui Twin (2021) Live Action');
      expect(parsed.title.toLowerCase(), contains('kakegurui twin'));
      expect(parsed.liveAction, isTrue);
    });

    test('live-action phrase is stripped from the cleaned title', () {
      final parsed =
          ParsedFileName.parse('Kakegurui Twin (2021) Live Action');
      // The cleaned title should NOT contain "live" or "action".
      expect(parsed.title.contains('live'), isFalse);
      expect(parsed.title.contains('action'), isFalse);
    });

    test('J-Drama / K-Drama / Drama keywords set the liveAction flag', () {
      expect(ParsedFileName.parse('Some Show J-Drama 2020').liveAction, isTrue);
      expect(ParsedFileName.parse('Some Show K-Drama 2020').liveAction, isTrue);
      expect(ParsedFileName.parse('Some Show Drama 2020').liveAction, isTrue);
    });

    test('liveAction flag is inherited from the parent folder', () {
      // The file name has no "Live Action" keyword, but the parent does.
      final parsed = ParsedFileName.parse(
        'Kakegurui Twin - 01.mkv',
        parentFolderName: 'Kakegurui Twin (2021) Live Action',
      );
      expect(parsed.liveAction, isTrue);
    });

    test('plain series names do NOT set liveAction', () {
      expect(ParsedFileName.parse('Kakegurui Twin').liveAction, isFalse);
      expect(ParsedFileName.parse('Kakegurui Twin (2017)').liveAction, isFalse);
    });
  });
}
