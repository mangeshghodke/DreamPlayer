import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/tmdb_api_key.dart';
import '../models/video_item.dart';

/// The TMDB poster URL (w185) for a cached meta, or null when there's no
/// poster. Shared by the folder/WebDAV/SMB row tiles that show per-file art.
String? posterUrlOf(TmdMeta? meta) => meta?.movie.posterPath == null
    ? null
    : 'https://image.tmdb.org/t/p/w185${meta!.movie.posterPath}';

/// What kind of title a matched file represents.
enum TmdKind { movie, tv }

/// A TMDB search hit (movie or series).
class TmdMovie {
  const TmdMovie({
    required this.id,
    required this.title,
    this.year,
    this.posterPath,
    this.backdropPath,
    this.overview = '',
    this.voteAverage = 0,
    this.kind = TmdKind.movie,
  });

  final int id;
  final String title;
  final int? year;
  final String? posterPath;
  final String? backdropPath;
  final String overview;
  final double voteAverage;
  final TmdKind kind;

  String? posterUrl({int width = 342}) =>
      posterPath == null ? null : 'https://image.tmdb.org/t/p/w$width$posterPath';

  String? backdropUrl({int width = 780}) => backdropPath == null
      ? null
      : 'https://image.tmdb.org/t/p/w$width$backdropPath';

  String get yearLabel => year != null ? '$year' : '';

  factory TmdMovie.fromJson(Map<String, dynamic> json, {TmdKind kind = TmdKind.movie}) {
    final date = json[kind == TmdKind.movie ? 'release_date' : 'first_air_date'] as String?;
    final year = date != null && date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null;
    return TmdMovie(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json[kind == TmdKind.movie ? 'title' : 'name'] as String?) ?? '',
      year: year,
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      overview: json['overview'] as String? ?? '',
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0,
      kind: kind,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'year': year,
        'posterPath': posterPath,
        'backdropPath': backdropPath,
        'overview': overview,
        'voteAverage': voteAverage,
        'kind': kind.name,
      };

  factory TmdMovie.fromMetaJson(Map<String, dynamic> json) => TmdMovie(
        id: (json['id'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        year: json['year'] as int?,
        posterPath: json['posterPath'] as String?,
        backdropPath: json['backdropPath'] as String?,
        overview: json['overview'] as String? ?? '',
        voteAverage: (json['voteAverage'] as num?)?.toDouble() ?? 0,
        kind: json['kind'] == 'tv' ? TmdKind.tv : TmdKind.movie,
      );
}

class TmdCastMember {
  const TmdCastMember({required this.name, this.character, this.profilePath});

  final String name;
  final String? character;
  final String? profilePath;

  String? profileUrl({int width = 185}) =>
      profilePath == null ? null : 'https://image.tmdb.org/t/p/w$width$profilePath';
}

class TmdDetails {
  const TmdDetails({
    required this.title,
    this.tagline,
    this.overview = '',
    this.voteAverage = 0,
    this.voteCount = 0,
    this.year,
    this.runtimeMinutes,
    this.genres = const [],
    this.cast = const [],
    this.posterPath,
    this.backdropPath,
    this.originalTitle,
    this.numberOfSeasons = 0,
    this.numberOfEpisodes = 0,
  });

  final String title;
  final String? tagline;
  final String overview;
  final double voteAverage;
  final int voteCount;
  final int? year;
  final int? runtimeMinutes;
  final List<String> genres;
  final List<TmdCastMember> cast;
  final String? posterPath;
  final String? backdropPath;
  final String? originalTitle;

  /// `number_of_seasons` / `number_of_episodes` from `/tv/{id}` (TV only;
  /// 0 for movies). Used to decide whether per-episode data is fetchable.
  final int numberOfSeasons;
  final int numberOfEpisodes;

  String get runtimeLabel =>
      runtimeMinutes == null ? '' : '${runtimeMinutes! ~/ 60}h ${runtimeMinutes! % 60}m';

  factory TmdDetails.fromJson(Map<String, dynamic> json, {TmdKind kind = TmdKind.movie}) {
    final date = json[kind == TmdKind.movie ? 'release_date' : 'first_air_date'] as String?;
    final year = date != null && date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null;
    final credits = json['credits'] as Map<String, dynamic>?;
    final castList = credits?['cast'] as List? ?? const [];
    return TmdDetails(
      title: (json[kind == TmdKind.movie ? 'title' : 'name'] as String?) ?? '',
      tagline: json['tagline'] as String?,
      overview: json['overview'] as String? ?? '',
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0,
      voteCount: (json['vote_count'] as num?)?.toInt() ?? 0,
      year: year,
      runtimeMinutes: _runtimeFromJson(json, kind),
      genres: (json['genres'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((g) => g['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList(),
      cast: castList
          .whereType<Map<String, dynamic>>()
          .take(12)
          .map(
            (c) => TmdCastMember(
              name: c['name'] as String? ?? '',
              character: c['character'] as String?,
              profilePath: c['profile_path'] as String?,
            ),
          )
          .where((c) => c.name.isNotEmpty)
          .toList(),
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      originalTitle: json[kind == TmdKind.movie ? 'original_title' : 'original_name'] as String?,
      numberOfSeasons: (json['number_of_seasons'] as num?)?.toInt() ?? 0,
      numberOfEpisodes: (json['number_of_episodes'] as num?)?.toInt() ?? 0,
    );
  }

  static int? _runtimeFromJson(Map<String, dynamic> json, TmdKind kind) {
    if (kind == TmdKind.movie) return (json['runtime'] as num?)?.toInt();
    final runtimes = json['episode_run_time'] as List?;
    if (runtimes == null || runtimes.isEmpty) return null;
    return (runtimes.first as num).toInt();
  }
}

/// One episode of a TV series (from `/tv/{id}/season/{n}`). Lets a local
/// `SxxExx` file show the episode's real TMDB name/overview. [cast] and
/// [stills] are only populated when the per-episode endpoint
/// (`/tv/{id}/season/{n}/episode/{m}` + `credits,images`) is fetched.
class TmdEpisode {
  const TmdEpisode({
    required this.episodeNumber,
    this.name = '',
    this.overview = '',
    this.stillPath,
    this.airDate,
    this.runtimeMinutes,
    this.voteAverage = 0,
    this.cast = const [],
    this.guestStars = const [],
    this.stills = const [],
  });

  final int episodeNumber;
  final String name;
  final String overview;
  final String? stillPath;
  final String? airDate;
  final int? runtimeMinutes;
  final double voteAverage;

  /// Guests/main cast from the episode's `credits` (may be empty).
  final List<TmdCastMember> cast;

  /// `credits.guest_stars` — the credited guest actors of this episode.
  final List<TmdCastMember> guestStars;

  /// Still-frame file paths (no host) from the episode's `images.stills`.
  final List<String> stills;

  String? stillUrl({int width = 300}) =>
      stillPath == null ? null : 'https://image.tmdb.org/t/p/w$width$stillPath';

  /// Absolute URLs for every still in [stills] (wide enough for a gallery row).
  List<String> stillUrls({int width = 500}) => stills
      .map((s) => 'https://image.tmdb.org/t/p/w$width$s')
      .toList();

  /// Falls back to "Episode N" so tiles never show a blank name.
  String get nameLabel => name.isEmpty ? 'Episode $episodeNumber' : name;

  /// Copy with [stills] replaced (used to merge the dedicated /images gallery
  /// into an episode whose `append_to_response=images` was empty).
  TmdEpisode withStills(List<String> stills) => TmdEpisode(
        episodeNumber: episodeNumber,
        name: name,
        overview: overview,
        stillPath: stillPath,
        airDate: airDate,
        runtimeMinutes: runtimeMinutes,
        voteAverage: voteAverage,
        cast: cast,
        guestStars: guestStars,
        stills: stills,
      );

  factory TmdEpisode.fromJson(Map<String, dynamic> json) {
    final credits = json['credits'] as Map<String, dynamic>?;
    final apiCast = credits?['cast'] as List?;
    final castList = (apiCast != null && apiCast.isNotEmpty)
        ? apiCast
        : (json['cast'] as List? ?? const []);
    final apiGuests = credits?['guest_stars'] as List?;
    final guestList = (apiGuests != null && apiGuests.isNotEmpty)
        ? apiGuests
        : (json['guestStars'] as List? ?? const []);
    final images = json['images'] as Map<String, dynamic>?;
    final apiStills = images?['stills'] as List?;
    final stills = (apiStills != null && apiStills.isNotEmpty)
        ? apiStills
            .whereType<Map<String, dynamic>>()
            .map((s) => s['file_path'] as String?)
            .whereType<String>()
            .toList()
        : (json['stills'] as List? ?? const []).whereType<String>().toList();
    return TmdEpisode(
      episodeNumber: (json['episode_number'] ?? json['episodeNumber'] as num?)
              ?.toInt() ??
          0,
      name: json['name'] as String? ?? '',
      overview: json['overview'] as String? ?? '',
      stillPath: (json['still_path'] ?? json['stillPath']) as String?,
      airDate: (json['air_date'] ?? json['airDate']) as String?,
      runtimeMinutes: (json['runtime'] ?? json['runtimeMinutes'] as num?)
          ?.toInt(),
      voteAverage: (json['vote_average'] ?? json['voteAverage'] as num?)
              ?.toDouble() ??
          0,
      cast: _castMembersFrom(castList),
      guestStars: _castMembersFrom(guestList),
      stills: stills,
    );
  }

  /// Maps a JSON cast list (API `credits.cast` / `credits.guest_stars` or the
  /// camelCase cache key) to [TmdCastMember]s, dropping blank names.
  static List<TmdCastMember> _castMembersFrom(List? list) => list
      ?.whereType<Map<String, dynamic>>()
      .map(
        (c) => TmdCastMember(
          name: c['name'] as String? ?? '',
          character: (c['character'] ?? c['role']) as String?,
          profilePath: (c['profile_path'] ?? c['profilePath']) as String?,
        ),
      )
      .where((c) => c.name.isNotEmpty)
      .toList() ??
      const [];

  Map<String, dynamic> toJson() => {
        'episodeNumber': episodeNumber,
        'name': name,
        'overview': overview,
        'stillPath': stillPath,
        'airDate': airDate,
        'runtimeMinutes': runtimeMinutes,
        'voteAverage': voteAverage,
        'cast': cast
            .map(
              (c) => {
                'name': c.name,
                'character': c.character,
                'profilePath': c.profilePath,
              },
            )
            .toList(),
        'guestStars': guestStars
            .map(
              (c) => {
                'name': c.name,
                'character': c.character,
                'profilePath': c.profilePath,
              },
            )
            .toList(),
        'stills': stills,
      };
}

/// A season's episode list, keyed by season number in [TmdMeta.seasons] so
/// folder screens can match local files against TMDB per episode.
class TmdSeason {
  const TmdSeason({
    required this.seasonNumber,
    this.name = '',
    this.episodes = const [],
  });

  final int seasonNumber;
  final String name;
  final List<TmdEpisode> episodes;

  TmdEpisode? episode(int episodeNumber) {
    for (final e in episodes) {
      if (e.episodeNumber == episodeNumber) return e;
    }
    return null;
  }

  /// Returns a copy with [replacement] swapped in for its episode number.
  TmdSeason withEpisode(TmdEpisode replacement) {
    final next = List<TmdEpisode>.of(episodes);
    final index =
        next.indexWhere((e) => e.episodeNumber == replacement.episodeNumber);
    if (index >= 0) {
      next[index] = replacement;
    } else {
      next.add(replacement);
    }
    return TmdSeason(seasonNumber: seasonNumber, name: name, episodes: next);
  }

  factory TmdSeason.fromJson(Map<String, dynamic> json) => TmdSeason(
        seasonNumber:
            (json['season_number'] ?? json['seasonNumber'] as num?)?.toInt() ??
                0,
        name: json['name'] as String? ?? '',
        episodes: (json['episodes'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TmdEpisode.fromJson)
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'seasonNumber': seasonNumber,
        'name': name,
        'episodes': episodes.map((e) => e.toJson()).toList(),
      };
}

/// Result of matching a cleaned filename against TMDB search results.
class TmdMatch {
  const TmdMatch(this.movie, this.score);

  final TmdMovie movie;
  final double score;
}

/// One entry from TMDB's `/{id}/translations` endpoint, narrowed to the
/// three fields DreamPlayer cares about (title, tagline, overview) so the
/// fallback decision tree can stay terse.
class TmdTranslation {
  const TmdTranslation({
    required this.language,
    required this.title,
    required this.tagline,
    required this.overview,
  });
  final String language;
  final String title;
  final String tagline;
  final String overview;
}

/// Cached per-video metadata (what the card shows + optional full details +
/// optional per-season episode data for TV shows).
class TmdMeta {
  const TmdMeta({
    required this.movie,
    this.details,
    this.seasons = const {},
  });

  final TmdMovie movie;
  final TmdDetails? details;

  /// Season number → [TmdSeason], filled lazily for TV shows whose episodes
  /// the user actually has locally.
  final Map<int, TmdSeason> seasons;

  TmdMeta withDetails(TmdDetails d) => TmdMeta(movie: movie, details: d, seasons: seasons);

  TmdMeta withSeason(TmdSeason season) {
    final next = Map<int, TmdSeason>.of(seasons);
    next[season.seasonNumber] = season;
    return TmdMeta(movie: movie, details: details, seasons: next);
  }

  Map<String, dynamic> toJson() => {
        'movie': movie.toJson(),
        'details': details == null ? null : _detailsToJson(details!),
        'seasons': seasons.values.map((s) => s.toJson()).toList(),
      };

  static Map<String, dynamic> _detailsToJson(TmdDetails d) => {
        'title': d.title,
        'tagline': d.tagline,
        'overview': d.overview,
        'voteAverage': d.voteAverage,
        'voteCount': d.voteCount,
        'year': d.year,
        'runtimeMinutes': d.runtimeMinutes,
        'genres': d.genres,
        'cast': d.cast
            .map(
              (c) => {'name': c.name, 'character': c.character, 'profilePath': c.profilePath},
            )
            .toList(),
        'posterPath': d.posterPath,
        'backdropPath': d.backdropPath,
        'originalTitle': d.originalTitle,
        'numberOfSeasons': d.numberOfSeasons,
        'numberOfEpisodes': d.numberOfEpisodes,
      };

  factory TmdMeta.fromJson(Map<String, dynamic> json) {
    final movieJson = json['movie'] as Map<String, dynamic>?;
    if (movieJson == null) {
      throw const FormatException('no movie in meta');
    }
    final seasonsRaw = json['seasons'] as List? ?? const [];
    final seasons = <int, TmdSeason>{};
    for (final s in seasonsRaw.whereType<Map<String, dynamic>>()) {
      final season = TmdSeason.fromJson(s);
      seasons[season.seasonNumber] = season;
    }
    return TmdMeta(
      movie: TmdMovie.fromMetaJson(movieJson),
      details: _detailsFromJson(json['details'] as Map<String, dynamic>?),
      seasons: seasons,
    );
  }

  static TmdDetails? _detailsFromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return TmdDetails(
      title: json['title'] as String? ?? '',
      tagline: json['tagline'] as String?,
      overview: json['overview'] as String? ?? '',
      voteAverage: (json['voteAverage'] as num?)?.toDouble() ?? 0,
      voteCount: (json['voteCount'] as num?)?.toInt() ?? 0,
      year: json['year'] as int?,
      runtimeMinutes: json['runtimeMinutes'] as int?,
      genres: (json['genres'] as List? ?? const []).cast<String>(),
      cast: (json['cast'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(
            (c) => TmdCastMember(
              name: c['name'] as String? ?? '',
              character: c['character'] as String?,
              profilePath: c['profilePath'] as String?,
            ),
          )
          .toList(),
      posterPath: json['posterPath'] as String?,
      backdropPath: json['backdropPath'] as String?,
      originalTitle: json['originalTitle'] as String?,
      numberOfSeasons: json['numberOfSeasons'] as int? ?? 0,
      numberOfEpisodes: json['numberOfEpisodes'] as int? ?? 0,
    );
  }
}

/// Parses a video filename into a searchable title + year.
class ParsedFileName {
  const ParsedFileName({
    required this.title,
    this.year,
    this.isEpisode = false,
    this.seriesName,
    this.season = 0,
    this.episode = 0,
  });

  final String title;
  final int? year;
  final bool isEpisode;
  final String? seriesName;

  /// Season number parsed from `SxxEyy` / `x.yy` (0 for movies).
  final int season;

  /// Episode number parsed from `SxxEyy` / `x.yy` (0 for movies).
  final int episode;

  /// `S02E04`-style label; empty for movies.
  String get episodeLabel => isEpisode
      ? 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
      : '';

  /// `Season 2 · Episode 4`; empty for movies.
  String get seasonEpisodeLabel =>
      isEpisode ? 'Season $season · Episode $episode' : '';

  static final RegExp _yearPattern = RegExp(r'\b(18|19|20)\d{2}\b');
  static final RegExp _episodePattern = RegExp(r'\bS(\d{1,2})E(\d{1,2})\b', caseSensitive: false);
  static final RegExp _episodeShortPattern =
      RegExp(r'\b(\d{1,2})x(\d{1,3})\b', caseSensitive: false);
  // Flux-style extra patterns: `se1ep2`, `season1episode2` (separators
  // optional). Matches `House.Season1Episode02.mkv`, `Show.Se1Ep2.mkv`,
  // `show.name.season01.episode02.1080p.mkv`, etc.
  static final RegExp _episodeLongPattern = RegExp(
      r'\b[Ss]eason\s*\.?\s*(\d{1,2})\s*\.?\s*[Ee]pisode\s*\.?\s*(\d{1,4})\b');
  static final RegExp _episodeSePattern = RegExp(
      r'\b[Ss]e\s*\.?\s*(\d{1,2})\s*\.?\s*[Ee]p\s*\.?\s*(\d{1,4})\b',
      caseSensitive: false);

  /// Bare season tag (`S02`, `S1`) — used by TV-season folder names like
  /// `HOUSE.S02.1080p...`. There's no episode number, so this is a whole
  /// season; the tag must be stripped or it pollutes the search title.
  static final RegExp _seasonOnlyPattern =
      RegExp(r'\bS(\d{1,2})\b', caseSensitive: false);

  static const List<String> _noise = [
    '1080p', '720p', '2160p', '480p', '4k', 'uhd', 'hd', 'sdr',
    'bluray', 'blu-ray', 'bdremux', 'remux', 'web-dl',     'webdl', 'webrip', 'web',
    'hdtv', 'dvdrip', 'h264', 'h265', 'x264', 'x265', 'hevc', 'avc', 'av1', 'vp9',
    'aac', 'ac3', 'eac3', 'dts', 'dts-hd', 'truehd', 'atmos', 'ma', 'flac', 'opus',
    'mp3',
    'ddp', '5.1', '7.1', '2.0', '10bit', '8bit', 'hdr', 'hdr10', 'hdr10plus',
    'dolby',
    'vision', 'dv', 'hdr10+', 'multi', 'proper', 'repack', 'internal', 'extended',
    'unrated', 'directors', 'cut', 'imax', 'complete',
    'english', 'eng', 'hindi', 'tamil', 'telugu', 'korean', 'japanese', 'spanish',
    'french', 'german', 'uncut', 'esub', 'subs', 'subtitle', 'tk',
    'nf', 'netflix', 'amzn', 'amazon', 'hbo', 'hulu', 'hdhub4u', 'hdbr',
  ];

  static ParsedFileName parse(String fileName, {String? parentFolderName}) {
    var name = fileName.trim();
    final dot = name.lastIndexOf('.');
    if (dot > 0) {
      final ext = name.substring(dot + 1).toLowerCase();
      if (ext.length <= 4) name = name.substring(0, dot);
    }

    // Audio/subtitle metadata often lives in brackets
    // (`[Hindi AMZN DDP 2.0 224kbps + English DTS-HD MA 5.1]`) or parens
    // (`(Hindi DDP 5.1  Korean DTS 5.1)`). Drop the whole group so the search
    // query is the title, not the audio track list — unless the group carries
    // the episode tag (`[S02E04]`) or the year (`(2013)`), which must stay for
    // episode / year detection.
    bool keepGroup(String s) =>
        _episodePattern.hasMatch(s) ||
        _episodeShortPattern.hasMatch(s) ||
        _yearPattern.hasMatch(s);
    name = name.replaceAllMapped(
      RegExp(r'\[[^\]]*\]'),
      (m) => keepGroup(m.group(0)!) ? m.group(0)! : ' ',
    );
    name = name.replaceAllMapped(
      RegExp(r'\([^)]*\)'),
      (m) => keepGroup(m.group(0)!) ? m.group(0)! : ' ',
    );

    // Bitrate annotations (`224kbps`, `640kbps`).
    name = name.replaceAll(RegExp(r'\b\d+\s?kbps\b', caseSensitive: false), ' ');

    // Release-group suffix is conventionally attached with a dash
    // (e.g. `...x265-GROUP`). Drop everything from the last dash on. When the
    // group is followed by a site/domain (`USURY-4kHdHub.com`), the segment
    // after the final dash contains a dot — additionally drop the group token
    // sitting right before the dash when it's an all-caps release-group name
    // (`USURY`), so the search query stays title-only.
    final dash = name.lastIndexOf('-');
    if (dash > 0) {
      final beforeDash = name.substring(0, dash);
      final site = name.substring(dash + 1);
      if (site.contains('.')) {
        final space = beforeDash.lastIndexOf(' ');
        if (space > 0) {
          final groupToken = beforeDash.substring(space + 1);
          if (groupToken.length <= 12 &&
              groupToken == groupToken.toUpperCase()) {
            name = beforeDash.substring(0, space);
          } else {
            name = beforeDash;
          }
        } else {
          name = beforeDash;
        }
      } else {
        name = beforeDash;
      }
    }

    final episodeMatch = _episodePattern.firstMatch(name);
    final shortEpisodeMatch = _episodeShortPattern.firstMatch(name);
    final longEpisodeMatch = _episodeLongPattern.firstMatch(name);
    final seEpisodeMatch = _episodeSePattern.firstMatch(name);
    final seasonOnlyMatch = _seasonOnlyPattern.firstMatch(name);

    final yearMatch = _yearPattern.firstMatch(name);
    int? year;
    if (yearMatch != null && yearMatch.start > 0) {
      // Flux-style guard: the year MUST NOT be at position 0 — otherwise
      // `2001.A.Space.Odyssey.1080p.mkv` would falsely extract 2001 as the
      // year. Same reason we look for a word boundary before the year.
      // (Already enforced by `\b`; this also drops a leading-year match.)
      year = int.parse(yearMatch.group(0)!);
      name = name.replaceAll(yearMatch.group(0)!, ' ');
    }

    var isEpisode = false;
    String? seriesName;
    var season = 0;
    var episode = 0;
    if (episodeMatch != null) {
      isEpisode = true;
      season = int.parse(episodeMatch.group(1)!);
      episode = int.parse(episodeMatch.group(2)!);
      seriesName = name.substring(0, episodeMatch.start).trim();
      name = name.replaceAll(episodeMatch.group(0)!, ' ');
    } else if (shortEpisodeMatch != null) {
      isEpisode = true;
      season = int.parse(shortEpisodeMatch.group(1)!);
      episode = int.parse(shortEpisodeMatch.group(2)!);
      seriesName = name.substring(0, shortEpisodeMatch.start).trim();
      name = name.replaceAll(shortEpisodeMatch.group(0)!, ' ');
    } else if (longEpisodeMatch != null) {
      // Flux-style: `House.Season1Episode02.mkv`
      isEpisode = true;
      season = int.parse(longEpisodeMatch.group(1)!);
      episode = int.parse(longEpisodeMatch.group(2)!);
      seriesName = name.substring(0, longEpisodeMatch.start).trim();
      name = name.replaceAll(longEpisodeMatch.group(0)!, ' ');
    } else if (seEpisodeMatch != null) {
      // Flux-style: `Show.Se1Ep2.mkv`
      isEpisode = true;
      season = int.parse(seEpisodeMatch.group(1)!);
      episode = int.parse(seEpisodeMatch.group(2)!);
      seriesName = name.substring(0, seEpisodeMatch.start).trim();
      name = name.replaceAll(seEpisodeMatch.group(0)!, ' ');
    } else if (seasonOnlyMatch != null) {
      // Whole-season folder (`Show.S02.1080p...`): keep the season number for
      // context but drop the tag so the cleaned title stays searchable.
      season = int.parse(seasonOnlyMatch.group(1)!);
      seriesName = name.substring(0, seasonOnlyMatch.start).trim();
      name = name.replaceAll(seasonOnlyMatch.group(0)!, ' ');
    }

    final title = _cleanName(name);
    // Flux-style fallback: when the file is just an episode number
    // (`Episode01.mkv`, `01.mkv`) or has no searchable title, fall back to
    // the parent folder's name as the series name. The folder is typically
    // named `Show.Name.(2021)` or `Show.Name.Season.1` — same parser rules
    // apply, but we don't try to extract an episode number from the folder
    // (we already have one from the file).
    String? effectiveSeriesName = seriesName;
    if (effectiveSeriesName == null &&
        parentFolderName != null &&
        parentFolderName.isNotEmpty &&
        !_hasEpisodePattern(parentFolderName)) {
      final folderParsed = parse(parentFolderName);
      effectiveSeriesName = folderParsed.title.isNotEmpty
          ? folderParsed.title
          : _cleanName(parentFolderName);
      // If the folder carried a year (e.g. `Kakegurui Twin(2021)`), use it
      // for the TMDB search too — `search/tv` supports a first_air_date_year.
      if (year == null && folderParsed.year != null) {
        year = folderParsed.year;
      }
    }
    return ParsedFileName(
      title: title.isEmpty
          ? (effectiveSeriesName ?? _fallbackTitle(fileName))
          : title,
      year: year,
      isEpisode: isEpisode,
      seriesName:
          effectiveSeriesName == null ? null : _cleanName(effectiveSeriesName),
      season: season,
      episode: episode,
    );
  }

  /// Quick test: does [text] contain any of the episode markers? Used to
  /// avoid inheriting the file's episode tag from a parent folder name.
  static bool _hasEpisodePattern(String text) =>
      _episodePattern.hasMatch(text) ||
      _episodeShortPattern.hasMatch(text) ||
      _episodeLongPattern.hasMatch(text) ||
      _episodeSePattern.hasMatch(text);

  static String _cleanName(String raw) {
    var cleaned = raw;
    // Underscore/bracket-glued tags (`_1080p`, `_[S02E04]_`) defeat the
    // word-boundary noise rules (underscore is a word char, `[`/`]` aren't);
    // normalize them to spaces up front. Dots and dashes stay until the
    // codec-glue regex runs below.
    cleaned = cleaned.replaceAll(RegExp(r'[_\[\](){}]'), ' ');
    // Codec tags glued to their channel layout (e.g. `DDP5.1`, `AC3.5.1`).
    cleaned = cleaned.replaceAll(
      RegExp(r'\b[a-z]{2,}\d+\.\d+\b', caseSensitive: false),
      ' ',
    );
    // `H.265` / `H265` / `H 265` (and X.264/265) survive the noise list
    // because of the dot/space — catch them explicitly before splitting.
    cleaned = cleaned.replaceAll(
      RegExp(r'\b[xh]\.?\s*26[0-9]\b', caseSensitive: false),
      ' ',
    );
    for (final n in _noise) {
      cleaned = cleaned.replaceAll(RegExp('\\b${RegExp.escape(n)}\\b', caseSensitive: false), ' ');
    }
    cleaned = cleaned.replaceAll(RegExp(r'[._\-\u2013\u2014\[\](){}]'), ' ');
    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _fallbackTitle(String fileName) {
    final cleaned = fileName.replaceAll(RegExp(r'[._\-\u2013\u2014\[\](){}]'), ' ');
    final parts = cleaned.split(' ').where((w) => w.isNotEmpty).take(6);
    return parts.join(' ');
  }
}

/// Talks to The Movie Database (TMDB) v3 API over `dart:io` HttpClient.
class TmdApi {
  TmdApi({this.apiKey});

  /// Explicit override; when set, [effectiveApiKey] uses it instead of the
  /// compile-time default (empty string = force no default, for tests).
  final String? apiKey;
  static const String _baseUrl = 'https://api.themoviedb.org/3';

  static const String prefsKey = 'dreamplayer.tmdbApiKey';

  /// One shared, keep-alive client for the whole app lifetime. A fresh
  /// `HttpClient` per request re-arms DNS + TLS each time and churns sockets,
  /// which on a flaky Wi-Fi/mobile link is slow and surfaces as intermittent
  /// `SocketException`s. Pooling the connection avoids that and speeds up
  /// bursts (home screen pre-resolves continue-watching cards in parallel).
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  /// Effective key: an explicit [TmdApi.apiKey] wins (empty = force no
  /// default); otherwise the compile-time default
  /// (`--dart-define=TMDB_API_KEY=...`, see `lib/config/tmdb_api_key.dart`).
  /// The build-time default is seeded into prefs on first use so the app keeps
  /// working on later `flutter run`s that omit the define.
  Future<String> effectiveApiKey() async {
    if (apiKey != null && apiKey!.isNotEmpty) return apiKey!;
    final prefs = await SharedPreferences.getInstance();
    var saved = prefs.getString(prefsKey);
    final defaultKey = apiKey ?? tmdbDefaultApiKey;
    if ((saved == null || saved.isEmpty) && defaultKey.isNotEmpty) {
      await prefs.setString(prefsKey, defaultKey);
      saved = defaultKey;
    }
    if (saved != null && saved.isNotEmpty) return saved;
    return '';
  }

  Future<List<TmdMovie>> search(String query, {int? year, TmdKind kind = TmdKind.movie}) async {
    final key = await effectiveApiKey();
    if (key.isEmpty) return const [];
    final endpoint = kind == TmdKind.movie ? '/search/movie' : '/search/tv';
    final params = <String, String>{
      'api_key': key,
      'query': query,
      'language': 'en-US',
      'include_adult': 'false',
      if (year != null) 'year': '$year',
    };
    final json = await _get('$endpoint?${_query(params)}');
    final results = json['results'] as List? ?? const [];
    return results
        .whereType<Map<String, dynamic>>()
        .map((r) => TmdMovie.fromJson(r, kind: kind))
        .where((m) => m.id != 0)
        .toList();
  }

  Future<TmdDetails> details(TmdMovie movie) async {
    final key = await effectiveApiKey();
    final endpoint = movie.kind == TmdKind.movie ? '/movie/${movie.id}' : '/tv/${movie.id}';
    final json = await _get('$endpoint?api_key=$key&language=en-US&append_to_response=credits');
    var details = TmdDetails.fromJson(json, kind: movie.kind);
    // Flux-style translation fallback: if title or overview is blank (TMDB
    // returns blanks for many non-English items in en-US), re-fetch the
    // translations endpoint and pick the best available translation.
    // This is genuinely better than our prior `append_to_response` approach
    // for users with non-English content.
    if (details.title.isEmpty || details.overview.isEmpty) {
      final translation = await bestTranslation(movie);
      if (translation != null) {
        details = TmdDetails(
          title: translation.title.isNotEmpty ? translation.title : details.title,
          tagline: translation.tagline.isNotEmpty ? translation.tagline : details.tagline,
          overview: translation.overview.isNotEmpty
              ? translation.overview
              : details.overview,
          voteAverage: details.voteAverage,
          voteCount: details.voteCount,
          year: details.year,
          runtimeMinutes: details.runtimeMinutes,
          genres: details.genres,
          cast: details.cast,
          posterPath: details.posterPath,
          backdropPath: details.backdropPath,
          originalTitle: details.originalTitle,
          numberOfSeasons: details.numberOfSeasons,
          numberOfEpisodes: details.numberOfEpisodes,
        );
      }
    }
    return details;
  }

  /// Pulls the translations list for [movie] (movie or TV) and returns the
  /// best matching translation: device locale first, English fallback, with
  /// a non-blank overview. Returns null when no useful translation exists.
  Future<TmdTranslation?> bestTranslation(TmdMovie movie) async {
    final key = await effectiveApiKey();
    if (key.isEmpty) return null;
    final endpoint = movie.kind == TmdKind.movie
        ? '/movie/${movie.id}/translations'
        : '/tv/${movie.id}/translations';
    final Map<String, dynamic> json;
    try {
      json = await _get('$endpoint?api_key=$key');
    } on TmdException catch (_) {
      return null;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    }
    final raw = json['translations'] as List? ?? const [];
    final translations = raw
        .whereType<Map<String, dynamic>>()
        .map((t) {
          final iso = t['iso_639_1'] as String? ?? '';
          final data = t['data'] as Map<String, dynamic>?;
          return TmdTranslation(
            language: iso,
            title: (data?['name'] as String? ?? '').trim(),
            tagline: (data?['tagline'] as String? ?? '').trim(),
            overview: (data?['overview'] as String? ?? '').trim(),
          );
        })
        .where((t) => t.language.isNotEmpty)
        .toList();
    if (translations.isEmpty) return null;

    // Device locale preference (e.g. `en_IN` → `en`). Empty string means
    // the locale query failed or the device has no language code.
    final lang = _deviceLanguage;
    return translations.cast<TmdTranslation?>().firstWhere(
          (t) =>
              t != null &&
              t.language == lang &&
              t.overview.isNotEmpty,
          orElse: () => translations.cast<TmdTranslation?>().firstWhere(
                (t) => t != null && t.language == 'en' && t.overview.isNotEmpty,
                orElse: () => translations.cast<TmdTranslation?>().firstWhere(
                      (t) => t != null && t.overview.isNotEmpty,
                      orElse: () => null,
                    ),
              ),
        );
  }

  /// Two-letter device language (`en`, `hi`, `fr`, ...). Falls back to empty
  /// string so the English fallback in [bestTranslation] takes over.
  String get _deviceLanguage {
    final locale = PlatformDispatcher.instance.locale;
    final lang = locale.languageCode.toLowerCase();
    return lang.isNotEmpty ? lang : '';
  }

  /// Episodes of one season (`/tv/{id}/season/{n}`), in one request. Empty when
  /// there's no key configured or the payload has no episodes.
  Future<List<TmdEpisode>> seasonEpisodes(TmdMovie movie, int seasonNumber) async {
    final key = await effectiveApiKey();
    if (key.isEmpty || seasonNumber <= 0) return const [];
    final json = await _get(
      '/tv/${movie.id}/season/$seasonNumber?api_key=$key&language=en-US',
    );
    final episodes = json['episodes'] as List? ?? const [];
    return episodes
        .whereType<Map<String, dynamic>>()
        .map(TmdEpisode.fromJson)
        .where((e) => e.episodeNumber > 0)
        .toList();
  }

  /// Full details of one episode (`/tv/{id}/season/{n}/episode/{m}`) with its
  /// cast (`credits`) and stills (`images`). Null when no key is configured or
  /// the endpoint fails. The season endpoint already supplies the episode
  /// name/overview/still; this adds the guest cast + all still frames.
  Future<TmdEpisode?> episodeDetails(
    TmdMovie movie,
    int seasonNumber,
    int episodeNumber,
  ) async {
    final key = await effectiveApiKey();
    if (key.isEmpty || seasonNumber <= 0 || episodeNumber <= 0) return null;
    try {
      final json = await _get(
        '/tv/${movie.id}/season/$seasonNumber/episode/$episodeNumber'
        '?api_key=$key&language=en-US&append_to_response=credits,images',
      );
      final parsed = TmdEpisode.fromJson(json);
      if (parsed.episodeNumber <= 0) return null;
      // The episode endpoint's `append_to_response=images` can come back with
      // an empty stills list even when the episode has a gallery on the site —
      // the dedicated /images sub-endpoint is authoritative, so merge it in.
      if (parsed.stills.isEmpty) {
        final gallery = await episodeGallery(movie, seasonNumber, episodeNumber);
        if (gallery.isNotEmpty) return parsed.withStills(gallery);
      }
      return parsed;
    } on TmdException {
      return null;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  /// Every still-frame file path for one episode from the dedicated images
  /// endpoint (`/tv/{id}/season/{n}/episode/{m}/images`) — the same source the
  /// TMDB site's episode gallery uses. Used when the episode endpoint's
  /// `append_to_response=images` came back empty. Empty on failure.
  Future<List<String>> episodeGallery(
    TmdMovie movie,
    int seasonNumber,
    int episodeNumber,
  ) async {
    final key = await effectiveApiKey();
    if (key.isEmpty || seasonNumber <= 0 || episodeNumber <= 0) return const [];
    try {
      final json = await _get(
        '/tv/${movie.id}/season/$seasonNumber/episode/$episodeNumber/images'
        '?api_key=$key',
      );
      final stills = json['stills'] as List? ?? const [];
      final paths = stills
          .whereType<Map<String, dynamic>>()
          .map((s) => s['file_path'] as String?)
          .whereType<String>()
          .toList();
      return paths;
    } on TmdException {
      return const [];
    } on SocketException {
      return const [];
    } on TimeoutException {
      return const [];
    }
  }

  Future<TmdMatch?> bestMatch(ParsedFileName parsed) async {
    final key = await effectiveApiKey();
    if (key.isEmpty) return null;
    final kind = parsed.isEpisode ? TmdKind.tv : TmdKind.movie;
    final results = await search(
      parsed.isEpisode ? (parsed.seriesName ?? parsed.title) : parsed.title,
      year: kind == TmdKind.movie ? parsed.year : null,
      kind: kind,
    );
    if (results.isEmpty) return null;
    results.sort((a, b) => _score(b, parsed).compareTo(_score(a, parsed)));
    final best = results.first;
    final score = _score(best, parsed);
    if (score < 0.5) return null;
    return TmdMatch(best, score);
  }

  double _score(TmdMovie movie, ParsedFileName parsed) {
    final query = (parsed.isEpisode ? (parsed.seriesName ?? parsed.title) : parsed.title)
        .toLowerCase();
    final title = movie.title.toLowerCase();
    var score = 0.0;
    if (title == query) {
      score = 1.0;
    } else if (title.startsWith(query) || query.startsWith(title)) {
      score = 0.85;
    } else {
      final common = _commonWords(query, title);
      final ratio = title.isNotEmpty ? common / title.split(' ').length : 0;
      score = 0.6 * ratio.clamp(0.0, 1.0);
    }
    if (parsed.year != null && movie.year == parsed.year && !parsed.isEpisode) {
      score = (score + 0.15).clamp(0.0, 1.0);
    }
    return score;
  }

  /// Searches both TV and movie for an arbitrary query (e.g. a folder name)
  /// and returns the best match above the threshold, or null. TV hits get a
  /// hair of preference so an exact-title tie (same name is both a show and a
  /// movie) lands on the series — the primary folder use-case is TV folders.
  Future<TmdMatch?> bestForQuery(String query) async {
    final key = await effectiveApiKey();
    if (key.isEmpty) return null;
    final clean = query.trim();
    if (clean.isEmpty) return null;
    final tv = await search(clean, kind: TmdKind.tv);
    final movie = await search(clean, kind: TmdKind.movie);
    TmdMatch? best;
    void consider(TmdMovie candidate, double tieBoost) {
      final score = _queryScore(candidate, clean) + tieBoost;
      if (score < 0.5) return;
      if (best == null || score > best!.score) {
        best = TmdMatch(candidate, score);
      }
    }

    for (final m in tv) {
      consider(m, 0.001);
    }
    for (final m in movie) {
      consider(m, 0.0);
    }
    return best;
  }

  double _queryScore(TmdMovie movie, String query) {
    final q = query.toLowerCase();
    final title = movie.title.toLowerCase();
    var score = 0.0;
    if (title == q) {
      score = 1.0;
    } else if (title.startsWith(q) || q.startsWith(title)) {
      score = 0.85;
    } else {
      final common = _commonWords(q, title);
      final ratio = title.isNotEmpty ? common / title.split(' ').length : 0;
      score = 0.6 * ratio.clamp(0.0, 1.0);
    }
    return score;
  }

  static int _commonWords(String a, String b) {
    final words = b.split(' ');
    return words.where((w) => a.contains(w)).length;
  }

  Future<Map<String, dynamic>> _get(String pathAndQuery) async {
    final uri = Uri.parse('$_baseUrl$pathAndQuery');
    // Retry once for transient failures (flaky network, dropped keep-alive
    // socket, per-second rate-limit burst). Hard errors (bad key, bad payload)
    // fail immediately with their specific message.
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      try {
        final request =
            await _client.getUrl(uri).timeout(const Duration(seconds: 15));
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response =
            await request.close().timeout(const Duration(seconds: 30));
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode != 200) {
          // 429 is a rate-limit burst — retry once before surfacing it.
          if (response.statusCode == 429 && attempt == 0) continue;
          throw TmdException(_friendlyStatus(response.statusCode));
        }
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          throw const TmdException('Unexpected TMDB response.');
        }
        return decoded;
      } on TmdException {
        rethrow;
      } on SocketException {
        // Fall through to the retry (or the final error below).
      } on TimeoutException {
        // Fall through to the retry (or the final error below).
      }
    }
    throw const TmdException("Can't reach TMDB — check your connection.");
  }

  static String _friendlyStatus(int code) {
    switch (code) {
      case 401:
        return 'TMDB API key is invalid.';
      case 429:
        return 'TMDB rate limit reached — try again shortly.';
      default:
        return 'TMDB returned an error ($code).';
    }
  }

  static String _query(Map<String, String> params) =>
      params.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
}

class TmdException implements Exception {
  const TmdException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Caches [TmdMeta] per video identity (resumeKey ?? path ?? uri) in
/// shared_preferences and mirrors the in-memory map so the UI can rebuild when
/// metadata arrives.
class TmdStore {
  TmdStore._();

  static const String _prefsKey = 'dreamplayer.tmdbMeta';

  static final StoreNotifier changes = StoreNotifier();

  static String identityKeyFor(VideoItem video) =>
      video.resumeKey ?? video.path ?? video.uri ?? '';

  static Future<Map<String, TmdMeta>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final result = <String, TmdMeta>{};
      for (final entry in json.entries) {
        try {
          result[entry.key] =
              TmdMeta.fromJson((entry.value as Map).cast<String, dynamic>());
        } catch (_) {}
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(String identityKey, TmdMeta meta) async {
    if (identityKey.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    all[identityKey] = meta;
    await prefs.setString(
      _prefsKey,
      jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))),
    );
    changes.notify();
  }

  static Future<void> remove(String identityKey) async {
    if (identityKey.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    if (all.remove(identityKey) != null) {
      await prefs.setString(
        _prefsKey,
        jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))),
      );
      changes.notify();
    }
  }
}

/// Exposes [ChangeNotifier.notifyListeners] publicly so [TmdStore]'s static
/// methods can announce changes without tripping the `@protected` lint.
class StoreNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// App-wide facade: resolves filenames to TMDB metadata, serves cached results
/// to the UI, and notifies listeners when a resolution lands.
class TmdService extends ChangeNotifier {
  TmdService._();

  static final TmdService instance = TmdService._();

  final TmdApi _api = TmdApi();
  Map<String, TmdMeta> _cache = {};
  final Map<String, Future<TmdMeta?>> _pending = {};

  /// In-flight season/episode detail fetches (dedup only; these return
  /// non-[TmdMeta] types so they can't share the [_pending] future map).
  final Set<String> _pendingDetail = {};
  bool _loaded = false;

  bool get loaded => _loaded;

  TmdMeta? metaFor(String identityKey) => _cache[identityKey];

  bool isResolving(String identityKey) => _pending.containsKey(identityKey);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _cache = await TmdStore.loadAll();
    _loaded = true;
    notifyListeners();
  }

  /// Returns cached metadata, or resolves it from TMDB (search + match) and
  /// caches it. Returns null when there's no key configured or no match found.
  ///
  /// Concurrent calls for the same key share one in-flight search (the second
  /// caller awaits the first's future) so a prefetch racing a tap never yields
  /// a false "no match".
  Future<TmdMeta?> resolve(VideoItem video, {String? parentFolderName}) async {
    final identityKey = TmdStore.identityKeyFor(video);
    if (identityKey.isEmpty) return null;
    await ensureLoaded();
    final cached = _cache[identityKey];
    if (cached != null) {
      return cached;
    }
    final inFlight = _pending[identityKey];
    if (inFlight != null) {
      return inFlight;
    }

    final parsed = ParsedFileName.parse(
      video.title,
      parentFolderName: parentFolderName,
    );
    if (parsed.title.isEmpty) return null;

    final future = _resolveNow(identityKey, parsed);
    _pending[identityKey] = future;
    try {
      return await future;
    } finally {
      _pending.remove(identityKey);
      notifyListeners();
    }
  }

  Future<TmdMeta?> _resolveNow(String identityKey, ParsedFileName parsed) async {
    final match = await _api.bestMatch(parsed);
    if (match == null) {
      return null;
    }
    final meta = TmdMeta(movie: match.movie);
    _cache[identityKey] = meta;
    await TmdStore.save(identityKey, meta);
    return meta;
  }

  /// Resolves a folder's name against TMDB (TV preferred) so its library card
  /// can show the show's poster. Best-effort; null when nothing matches.
  /// [metadataKey] is the folder's stable identity (see `LibraryFolder`).
  Future<TmdMeta?> resolveFolder(String metadataKey, String folderName) async {
    await ensureLoaded();
    final cached = _cache[metadataKey];
    if (cached != null) return cached;
    final inFlight = _pending[metadataKey];
    if (inFlight != null) return inFlight;

    final parsed = ParsedFileName.parse(folderName);
    if (parsed.title.isEmpty) return null;

    final future = _resolveFolderNow(metadataKey, parsed.title);
    _pending[metadataKey] = future;
    try {
      return await future;
    } finally {
      _pending.remove(metadataKey);
      notifyListeners();
    }
  }

  Future<TmdMeta?> _resolveFolderNow(String metadataKey, String query) async {
    final match = await _api.bestForQuery(query);
    if (match == null) return null;
    final meta = TmdMeta(movie: match.movie);
    _cache[metadataKey] = meta;
    await TmdStore.save(metadataKey, meta);
    return meta;
  }

  /// Fetches full details (synopsis, cast, runtime) for a matched video.
  Future<TmdDetails?> detailsFor(String identityKey) async {
    final meta = _cache[identityKey];
    if (meta == null) return null;
    if (meta.details != null) return meta.details;
    try {
      final details = await _api.details(meta.movie);
      _cache[identityKey] = meta.withDetails(details);
      await TmdStore.save(identityKey, _cache[identityKey]!);
      notifyListeners();
      return details;
    } catch (_) {
      return null;
    }
  }

  /// Fetches + caches the episodes of one season for the show matched under
  /// [identityKey] (a folder key or a per-video key). Returns null when there's
  /// no cached match, it's not a TV show, or the request fails. Only the
  /// seasons the user actually has locally are ever fetched.
  Future<TmdSeason?> seasonFor(String identityKey, int seasonNumber) async {
    await ensureLoaded();
    if (seasonNumber <= 0) return null;
    final cached = _cache[identityKey];
    if (cached == null || cached.movie.kind != TmdKind.tv) return null;
    final already = cached.seasons[seasonNumber];
    if (already != null) return already;
    final pendingKey = '$identityKey#s$seasonNumber';
    if (_pendingDetail.contains(pendingKey)) return null;

    _pendingDetail.add(pendingKey);
    try {
      final episodes = await _api.seasonEpisodes(cached.movie, seasonNumber);
      if (episodes.isEmpty) return null;
      final season = TmdSeason(seasonNumber: seasonNumber, episodes: episodes);
      _cache[identityKey] = cached.withSeason(season);
      await TmdStore.save(identityKey, _cache[identityKey]!);
      return season;
    } catch (_) {
      return null;
    } finally {
      _pendingDetail.remove(pendingKey);
      notifyListeners();
    }
  }

  /// Fetches + caches the full details (guest cast, all stills) of one episode
  /// of the show matched under [identityKey], enriching the cached [TmdEpisode]
  /// in place. Returns the (possibly unchanged) episode when the fetch fails,
  /// or null when there's nothing cached to enrich.
  Future<TmdEpisode?> episodeDetailsFor(
    String identityKey,
    int seasonNumber,
    int episodeNumber,
  ) async {
    await ensureLoaded();
    final cached = _cache[identityKey];
    if (cached == null || cached.movie.kind != TmdKind.tv) return null;
    final season = cached.seasons[seasonNumber];
    if (season == null) return null;
    final existing = season.episode(episodeNumber);
    if (existing == null) return null;
    // Only a completed stills gallery short-circuits. Cast alone means an
    // earlier run hit the empty `append_to_response=images` case, so the
    // dedicated /images gallery must be retried.
    if (existing.stills.isNotEmpty) {
      return existing;
    }
    final pendingKey = '$identityKey#e$seasonNumber.$episodeNumber';
    if (_pendingDetail.contains(pendingKey)) return null;

    _pendingDetail.add(pendingKey);
    try {
      final enriched = await _api.episodeDetails(
        cached.movie,
        seasonNumber,
        episodeNumber,
      );
      if (enriched == null) return existing;
      _cache[identityKey] = cached.withSeason(season.withEpisode(enriched));
      await TmdStore.save(identityKey, _cache[identityKey]!);
      return enriched;
    } catch (_) {
      return existing;
    } finally {
      _pendingDetail.remove(pendingKey);
      notifyListeners();
    }
  }

  /// Manual fix: pins an explicitly chosen title for the video.
  Future<void> setManual(VideoItem video, TmdMovie movie) async {
    final identityKey = TmdStore.identityKeyFor(video);
    if (identityKey.isEmpty) return;
    _cache[identityKey] = TmdMeta(movie: movie);
    await TmdStore.save(identityKey, _cache[identityKey]!);
    notifyListeners();
  }

  /// Manual fix for a library folder (identity = `folder:<id>`), so the folder
  /// details screen can be pinned to a TV series without a video.
  Future<void> setManualFolder(String metadataKey, TmdMovie movie) async {
    await ensureLoaded();
    _cache[metadataKey] = TmdMeta(movie: movie);
    await TmdStore.save(metadataKey, _cache[metadataKey]!);
    notifyListeners();
  }

  /// Carries the full cached metadata (details + seasons) from [fromKey] to
  /// [toKey], so a video opened from a folder instantly has the show's season
  /// data (episode names/overviews/ratings/stills) without re-fetching it.
  /// [fromKey] is left untouched. Used by the folder details screen when an
  /// episode is tapped — the folder has already loaded the seasons, so the
  /// episode screen must not start from a bare movie and re-fetch on every tap.
  Future<void> carryMeta(String fromKey, String toKey) async {
    if (fromKey.isEmpty || toKey.isEmpty || fromKey == toKey) return;
    await ensureLoaded();
    // The folder meta may live only in prefs (e.g. a fresh process where the
    // folder screen hasn't resolved yet) — read it through so the carry still
    // works.
    final source =
        _cache[fromKey] ?? (await TmdStore.loadAll())[fromKey];
    if (source == null) return;
    _cache[fromKey] ??= source;
    _cache[toKey] = source;
    await TmdStore.save(toKey, source);
    notifyListeners();
  }

  Future<void> clear(String identityKey) async {
    _cache.remove(identityKey);
    await TmdStore.remove(identityKey);
    notifyListeners();
  }
}
