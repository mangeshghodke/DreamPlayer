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
    this.originalTitle,
  });

  final int id;
  final String title;
  final int? year;
  final String? posterPath;
  final String? backdropPath;
  final String overview;
  final double voteAverage;
  final TmdKind kind;
  final String? originalTitle;

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
      originalTitle: json[kind == TmdKind.movie ? 'original_title' : 'original_name'] as String?,
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
        'originalTitle': originalTitle,
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
        originalTitle: json['originalTitle'] as String?,
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

class TmdTrailer {
  const TmdTrailer({
    required this.key,
    required this.name,
    required this.site,
  });

  final String key;
  final String name;
  final String site;

  String? get youtubeUrl => site == 'YouTube'
      ? 'https://www.youtube.com/watch?v=$key'
      : null;
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
    this.trailers = const [],
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
  final List<TmdTrailer> trailers;
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
      trailers: _parseTrailers(json),
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

  static List<TmdTrailer> _parseTrailers(Map<String, dynamic> json) {
    final videos = json['videos'] as Map<String, dynamic>?;
    final results = videos?['results'] as List? ?? const [];
    return results
        .whereType<Map<String, dynamic>>()
        .where((v) => v['site'] == 'YouTube' && v['key'] != null)
        .take(5)
        .map(
          (v) => TmdTrailer(
            key: v['key'] as String,
            name: v['name'] as String? ?? 'Trailer',
            site: v['site'] as String? ?? 'YouTube',
          ),
        )
        .toList();
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
    this.overview = '',
    this.posterPath,
    this.episodes = const [],
  });

  final int seasonNumber;
  final String name;
  final String overview;
  final String? posterPath;
  final List<TmdEpisode> episodes;

  /// Full URL for the season poster (e.g. "Season 2" artwork).
  String? posterUrl({int width = 300}) =>
      posterPath == null ? null : 'https://image.tmdb.org/t/p/w$width$posterPath';

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
    return TmdSeason(
      seasonNumber: seasonNumber,
      name: name,
      overview: overview,
      posterPath: posterPath,
      episodes: next,
    );
  }

  factory TmdSeason.fromJson(Map<String, dynamic> json) => TmdSeason(
        seasonNumber:
            (json['season_number'] ?? json['seasonNumber'] as num?)?.toInt() ??
                0,
        name: json['name'] as String? ?? '',
        overview: json['overview'] as String? ?? '',
        posterPath: (json['poster_path'] ?? json['posterPath']) as String?,
        episodes: (json['episodes'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TmdEpisode.fromJson)
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'seasonNumber': seasonNumber,
        'name': name,
        'overview': overview,
        'posterPath': posterPath,
        'episodes': episodes.map((e) => e.toJson()).toList(),
      };
}

/// Result of matching a cleaned filename against TMDB search results.
class TmdMatch {
  const TmdMatch(this.movie, this.score);

  final TmdMovie movie;
  final double score;
}

/// Cached per-video metadata (what the card shows + optional full details +
/// optional per-season episode data for TV shows).
class TmdMeta {
  const TmdMeta({
    required this.movie,
    this.details,
    this.seasons = const {},
    this.folderSeason,
  });

  final TmdMovie movie;
  final TmdDetails? details;

  /// Season number → [TmdSeason], filled lazily for TV shows whose episodes
  /// the user actually has locally.
  final Map<int, TmdSeason> seasons;

  /// When a folder name matches a season name on TMDB (e.g. "Strike the Blood
  /// Final" → Season 5), this stores the matched season number so episode
  /// grouping uses it instead of the parsed season from the filename.
  final int? folderSeason;

  TmdMeta withDetails(TmdDetails d) => TmdMeta(
      movie: movie, details: d, seasons: seasons, folderSeason: folderSeason);

  TmdMeta withSeason(TmdSeason season) {
    final next = Map<int, TmdSeason>.of(seasons);
    next[season.seasonNumber] = season;
    return TmdMeta(
        movie: movie, details: details, seasons: next, folderSeason: folderSeason);
  }

  TmdMeta withFolderSeason(int s) => TmdMeta(
      movie: movie, details: details, seasons: seasons, folderSeason: s);

  Map<String, dynamic> toJson() => {
        'movie': movie.toJson(),
        'details': details == null ? null : _detailsToJson(details!),
        'seasons': seasons.values.map((s) => s.toJson()).toList(),
        if (folderSeason != null) 'folderSeason': folderSeason,
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
      folderSeason: json['folderSeason'] as int?,
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
  /// E01 / EP01 / EP1 style — no season prefix.  season defaults to 1
  /// (most folders are single-season), episode extracted from the number.
  static final RegExp _episodeOnlyPattern =
      RegExp(r'\bEP?(\d{1,3})\b', caseSensitive: false);
  /// [01] / [02] style — common anime fansub episode numbering in brackets.
  static final RegExp _bracketEpisodePattern =
      RegExp(r'\[(\d{1,3})\]');

  /// Bare season tag (`S02`, `S1`) — used by TV-season folder names like
  /// `HOUSE.S02.1080p...`. There's no episode number, so this is a whole
  /// season; the tag must be stripped or it pollutes the search title.
  static final RegExp _seasonOnlyPattern =
      RegExp(r'\bS(\d{1,2})\b', caseSensitive: false);

  static const List<String> _noise = [
    '1080p', '720p', '2160p', '480p', '4k', 'uhd', 'hd', 'sdr',
    'bluray', 'blu-ray', 'bdremux', 'remux', 'web-dl', 'webdl', 'webrip', 'web',
    'hdtv', 'sdtv', 'dvdrip', 'h264', 'h265', 'x264', 'x265', 'hevc', 'avc', 'av1', 'vp9',
    'aac', 'ac3', 'eac3', 'dts', 'dts-hd', 'truehd', 'atmos', 'ma', 'flac', 'opus',
    'mp3',
    'ddp', '5.1', '7.1', '2.0', '10bit', '8bit', 'hdr', 'hdr10', 'hdr10plus',
    'dolby',
    'vision', 'dv', 'hdr10+', 'multi', 'proper', 'repack', 'internal', 'extended',
    'unrated', 'directors', 'cut', 'imax', 'complete',
    'english', 'eng', 'hindi', 'tamil', 'telugu', 'korean', 'japanese', 'spanish',
    'french', 'german', 'uncut', 'esub', 'subs', 'subtitle', 'tk',
    'nf', 'netflix', 'amzn', 'amazon', 'hbo', 'hulu', 'hdhub4u', 'hdbr',
    // Nova-style additional garbage
    'dvdscr', 'bdrip', 'brrip', 'hdrip', 'hdlight', 'minibdrip',
    'xvid', 'divx', 'wmv', 'flv', 'f4v', 'asf', 'vob',
    'dts-x', 'dts-hd.ma', 'uhd', 'dolby',
    'hfr', 'multisubs', 'subforced', 'subforces',
    'truefrench', 'sbs', 'hsbs', '3d',
    'anaglyph', 'anaglyphe',
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
        _bracketEpisodePattern.hasMatch(s) ||
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

final yearMatch = _yearPattern.firstMatch(name);
    int? year;
    if (yearMatch != null && yearMatch.start > 0) {
      // Nova-style: extract the LAST year from the string (important for
      // `Show Name S01E01 (2019)` where 2019 is the year, not S01).
      // Find all year matches and take the last one.
      final allYears = _yearPattern.allMatches(name).toList();
      if (allYears.isNotEmpty) {
        final lastYear = allYears.last;
        if (lastYear.start > 0) {
          year = int.parse(lastYear.group(0)!);
          name = name.replaceAll(lastYear.group(0)!, ' ');
        }
      }
    }

    // Nova-style: remove empty parentheses left after year extraction
    name = name.replaceAll(RegExp(r'\(\s*\)'), ' ');

    // The year-strip above shrinks the string by 3 chars, shifting every
    // offset after the year. Run the episode regexes against the *trimmed*
    // name so `substring(0, m.start)` below uses fresh offsets. Otherwise
    // `Kakegurui Twin (2021) S01E01.mkv` ends up with
    // `seriesName = "Kakegurui Twin ( ) S01"` because the stale start leaks
    // `S01` into the series name and the TMDB search silently 404s.
    final episodeMatch = _episodePattern.firstMatch(name);
    final shortEpisodeMatch = _episodeShortPattern.firstMatch(name);
    final episodeOnlyMatch = _episodeOnlyPattern.firstMatch(name);
    final bracketMatch = _bracketEpisodePattern.firstMatch(name);
    final seasonOnlyMatch = _seasonOnlyPattern.firstMatch(name);

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
    } else if (episodeOnlyMatch != null) {
      // E01 / EP01 — episode-only tag with no season prefix.
      isEpisode = true;
      episode = int.parse(episodeOnlyMatch.group(1)!);
      seriesName = name.substring(0, episodeOnlyMatch.start).trim();
      name = name.replaceAll(episodeOnlyMatch.group(0)!, ' ');
    } else if (bracketMatch != null) {
      // [01] / [02] — bracket episode numbering (anime fansub style).
      isEpisode = true;
      episode = int.parse(bracketMatch.group(1)!);
      seriesName = name.substring(0, bracketMatch.start).trim();
      name = name.replaceAll(bracketMatch.group(0)!, ' ');
    } else if (seasonOnlyMatch != null) {
      // Whole-season folder (`Show.S02.1080p...`): keep the season number for
      // context but drop the tag so the cleaned title stays searchable.
      season = int.parse(seasonOnlyMatch.group(1)!);
      seriesName = name.substring(0, seasonOnlyMatch.start).trim();
      name = name.replaceAll(seasonOnlyMatch.group(0)!, ' ');
    }

    final title = _cleanName(name);
    // Fallback: when the file is just an episode number
    // (`Episode01.mkv`, `01.mkv`) or has no searchable title, fall back to
    // the parent folder's name as the series name.
    String? effectiveSeriesName = seriesName?.isNotEmpty == true ? seriesName : null;
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
      _episodeOnlyPattern.hasMatch(text) ||
      _bracketEpisodePattern.hasMatch(text);

  static String _cleanName(String raw) {
    var cleaned = raw;

    // Nova-style: strip out everything in brackets <[{( .. )})>, most of the time teams names, etc
    cleaned = cleaned.replaceAll(RegExp(r'[<({\[\]>)}\]]'), ' ');

    // Codec tags glued to their channel layout (e.g. `DDP5.1`, `AC3.5.1`).
    // Must run BEFORE dot replacement so `5.1` is still a contiguous token.
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

    // Nova-style: remove garbage case-sensitively (must be surrounded by separators)
    for (final g in _garbageCaseSensitive) {
      cleaned = cleaned.replaceAll(
        RegExp('[ ._-]$g(?:[ ._-]|\$)', caseSensitive: false),
        ' ',
      );
    }

    // Nova-style: remove garbage case-insensitively
    // Must run BEFORE dot/hyphen replacement so `5.1`, `7.1`, `2.0`, `WEB-DL`
    // are still contiguous tokens.
    for (final n in _noise) {
      cleaned = cleaned.replaceAll(
        RegExp('(?<![\\w])${RegExp.escape(n)}(?![\\w])', caseSensitive: false),
        ' ',
      );
    }

    // Nova-style: replace dots and underscores with spaces (AFTER noise removal)
    cleaned = cleaned.replaceAll(RegExp(r'[._]'), ' ');

    // Nova-style: replace hyphens, en-dashes, em-dashes with spaces
    // (AFTER noise removal so WEB-DL was already matched as a whole token)
    cleaned = cleaned.replaceAll(RegExp(r'[-\u2013\u2014]'), ' ');

    // Collapse multiple spaces and trim
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();

    return cleaned;
  }

  /// Nova-style: garbage that could be present in real names, matched with tight case sensitive syntax.
  /// These strings will only match if separated by any of " .-_".
  /// Note: WEB is NOT here — it conflicts with WEB-DL (the case-sensitive regex
  /// `.WEB-` matches the hyphen separator, eating WEB from WEB-DL and leaving DL).
  /// The noise list handles `web` and `web-dl` with proper word boundaries.
  static const List<String> _garbageCaseSensitive = [
    'FRENCH', 'TRUEFRENCH', 'DUAL', 'MULTISUBS', 'MULTI', 'MULTi',
    'SUBFORCED', 'SUBFORCES', 'UNRATED', 'EXTENDED', 'IMAX',
    'COMPLETE', 'PROPER', 'iNTERNAL', 'INTERNAL',
    'SUBBED', 'LIMITED', 'REMUX',
    'TS', 'TC', 'REAL', 'HD',
    'EN', 'ENG', 'FR', 'ES', 'IT', 'NL', 'VFQ', 'VF', 'VO',
    'VOST', 'VFF', 'VFI',
  ];

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
    final saved = prefs.getString(prefsKey);
    if (saved != null && saved.isNotEmpty) return saved;
    // No build-time default seeding (was previously seeded from
    // `--dart-define=TMDB_API_KEY=...` but removed in 0.3.9 so public
    // APK releases don't leak a bundled key — users enter their own in
    // Settings → Metadata). The build-time define is still injected for
    // the iOS GitHub Actions test build so the iPad IPA works without
    // first opening Settings.
    return tmdbDefaultApiKey;
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
      if (year != null) (kind == TmdKind.movie ? 'year' : 'first_air_date_year'): '$year',
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
    final json = await _get('$endpoint?api_key=$key&language=en-US&append_to_response=credits,videos');
    var details = TmdDetails.fromJson(json, kind: movie.kind);
    return details;
  }

  /// Fetches season names for a TV show from `/tv/{id}`.
  /// Returns a map of seasonNumber → seasonName (e.g. {5: "Strike the Blood Final"}).
  Future<Map<int, String>> seasonNames(TmdMovie movie) async {
    if (movie.kind != TmdKind.tv) return const {};
    final key = await effectiveApiKey();
    if (key.isEmpty) return const {};
    try {
      final json = await _get('/tv/${movie.id}?api_key=$key&language=en-US');
      final seasons = json['seasons'] as List? ?? const [];
      return {
        for (final s in seasons.whereType<Map<String, dynamic>>())
          (s['season_number'] as num?)?.toInt() ?? 0: s['name'] as String? ?? '',
      };
    } catch (_) {
      return const {};
    }
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
    final hasSeries = parsed.isEpisode || (parsed.seriesName?.isNotEmpty ?? false);
    final kind = hasSeries ? TmdKind.tv : TmdKind.movie;
    final query = hasSeries ? (parsed.seriesName ?? parsed.title) : parsed.title;

    var results = await search(
      query,
      year: kind == TmdKind.movie ? parsed.year : null,
      kind: kind,
    );

    if (results.isEmpty && parsed.year != null && kind == TmdKind.movie) {
      results = await search(query, kind: kind);
    }

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
    // Nova-style: Levenshtein distance for robust matching.
    final dist = _levenshteinDistance(query, title);
    final maxLen = query.length > title.length ? query.length : title.length;
    if (maxLen == 0) return 0.0;
    // Score = 1.0 for exact match, decays with edit distance.
    // threshold: distance ≤ 30% of max length = pass (≥ 0.5).
    var score = (1.0 - dist / maxLen).clamp(0.0, 1.0);

    // Nova-style: Year bonus — deliberately NOT clamped so it can break
    // ties when two results both score 1.0 on Levenshtein (exact match).
    if (parsed.year != null && movie.year == parsed.year) {
      if (!(parsed.isEpisode || (parsed.seriesName?.isNotEmpty ?? false))) {
        // Nova uses 0.15 for movie year match
        score += 0.15;
      } else {
        // Tiny tiebreaker for TV — only matters when two results tie on title.
        score += 0.01;
      }
    }

    return score;
  }

  /// Searches both TV and movie for an arbitrary query (e.g. a folder name)
  /// and returns the best match above the threshold, or null. TV hits get a
  /// hair of preference so an exact-title tie (same name is both a show and a
  /// movie) lands on the series — the primary folder use-case is TV folders.
  /// When [year] is provided, results matching that year are strongly boosted
  /// to disambiguate shows/movies with the same title but different years.
  Future<TmdMatch?> bestForQuery(String query, {int? year}) async {
    final key = await effectiveApiKey();
    if (key.isEmpty) return null;
    final clean = query.trim();
    if (clean.isEmpty) return null;
    final tv = await search(clean, year: year, kind: TmdKind.tv);
    final movie = await search(clean, year: year, kind: TmdKind.movie);
    TmdMatch? best;
    void consider(TmdMovie candidate, double tieBoost) {
      final score = _queryScore(candidate, clean, year: year) + tieBoost;
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

  double _queryScore(TmdMovie movie, String query, {int? year}) {
    final q = query.toLowerCase();
    final title = movie.title.toLowerCase();
    final dist = _levenshteinDistance(q, title);
    final maxLen = q.length > title.length ? q.length : title.length;
    if (maxLen == 0) return 0.0;
    var score = (1.0 - dist / maxLen).clamp(0.0, 1.0);

    // Year disambiguation: when a year is provided, strongly boost results
    // whose release year matches. This breaks ties between identically-named
    // shows (e.g. "Kakegurui Twin" 2017 vs 2022).
    if (year != null && score >= 0.5) {
      final candidateYear = movie.year;
      if (candidateYear == year) {
        score += 0.5;
      } else if (candidateYear != null) {
        score -= 0.1;
      }
    }

    return score;
  }

  /// Levenshtein edit distance (for TMDB title matching).
  static int _levenshteinDistance(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    // Optimisation: only need two rows at a time.
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var curr = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = [
          prev[j] + 1,      // deletion
          curr[j - 1] + 1,  // insertion
          prev[j - 1] + cost // substitution
        ].reduce((x, y) => x < y ? x : y);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[b.length];
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

  /// Last prefetch list — used by [_staggerPrefetch] to carry resolved meta
  /// to sibling files in the same series after each individual resolve.
  List<VideoItem> _lastPrefetchVideos = const [];

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

    final future = _resolveFolderNow(metadataKey, parsed.title, parsed.year);
    _pending[metadataKey] = future;
    try {
      return await future;
    } finally {
      _pending.remove(metadataKey);
      notifyListeners();
    }
  }

  Future<TmdMeta?> _resolveFolderNow(
      String metadataKey, String query, int? year) async {
    final match = await _api.bestForQuery(query, year: year);
    if (match == null) return null;

    // Check if the folder name matches a season name on TMDB.
    // e.g. "Strike the Blood Final" → Season 5 "Strike the Blood Final".
    int? folderSeason;
    if (match.movie.kind == TmdKind.tv) {
      final names = await _api.seasonNames(match.movie);
      folderSeason = _matchSeasonFromFolder(query, names);
    }

    final meta = TmdMeta(movie: match.movie, folderSeason: folderSeason);
    _cache[metadataKey] = meta;
    await TmdStore.save(metadataKey, meta);
    return meta;
  }

  /// Checks if [folderName] matches any season name in [seasonNames].
  /// Returns the matched season number, or null if no match.
  ///
  /// Matching strategy (prefers most specific / longest match):
  /// 1. Exact match (case-insensitive): "Strike the Blood Final" == "Strike the Blood Final"
  /// 2. One contains the other — prefer the LONGER season name (more specific)
  /// 3. Significant word overlap: all words of the shorter name appear in the longer
  int? _matchSeasonFromFolder(
      String folderName, Map<int, String> seasonNames) {
    final q = folderName.toLowerCase().trim();
    if (q.isEmpty || seasonNames.isEmpty) return null;

    int? bestSeason;
    var bestScore = 0;

    for (final entry in seasonNames.entries) {
      final sName = entry.value.toLowerCase().trim();
      if (sName.isEmpty) continue;

      // 1. Exact match — always wins
      if (q == sName) return entry.key;

      // 2. One contains the other
      if (sName.contains(q) || q.contains(sName)) {
        // Prefer the longer season name (more specific match)
        final score = sName.length;
        if (score > bestScore) {
          bestScore = score;
          bestSeason = entry.key;
        }
        continue;
      }

      // 3. Significant word overlap
      final qWords = q.split(RegExp(r'\s+')).where((w) => w.length > 2).toList();
      final sWords = sName.split(RegExp(r'\s+')).where((w) => w.length > 2).toList();
      if (qWords.isEmpty || sWords.isEmpty) continue;

      // All words of the shorter name must appear in the longer
      final shorter = qWords.length <= sWords.length ? qWords : sWords;
      final longer = qWords.length <= sWords.length ? sWords : qWords;
      if (shorter.every((w) => longer.contains(w))) {
        final score = shorter.length * 10 + sName.length;
        if (score > bestScore) {
          bestScore = score;
          bestSeason = entry.key;
        }
      }
    }
    return bestSeason;
  }

  /// Nova-style: background-resolve TMDB metadata for every video in a folder.
  /// Each file gets its own `resolve()` call; already-cached entries are
  /// skipped. Resolutions fire-and-forget with a small stagger to avoid
  /// hitting TMDB rate limits — callers listen to [notifyListeners] to pick
  /// up results as they land.
  void prefetchFolder(List<VideoItem> videos) {
    final pending = <VideoItem>[];
    for (final video in videos) {
      final key = TmdStore.identityKeyFor(video);
      if (key.isEmpty) continue;
      if (_cache.containsKey(key)) continue;
      if (_pending.containsKey(key)) continue;
      pending.add(video);
    }
    _lastPrefetchVideos = videos;
    // Stagger resolve calls to stay under TMDB rate limits (40 req/10 s).
    _staggerPrefetch(pending, 0);
  }

  void _staggerPrefetch(List<VideoItem> videos, int index) {
    if (index >= videos.length) return;
    resolve(videos[index]).then((_) {
      // After each file resolves, carry its meta to siblings in the same
      // series so other episodes get the show's poster without re-searching.
      _carrySeriesMetaToSiblings(videos[index]);
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      _staggerPrefetch(videos, index + 1);
    });
  }

  /// Nova-style: when a file resolves, check all prefetch-list files that
  /// share the same detected series name and carry the meta to any that
  /// are still unresolved.  This makes every episode in a TV folder show
  /// the show's poster as soon as the first episode resolves.
  void _carrySeriesMetaToSiblings(VideoItem resolved) {
    final resolvedKey = TmdStore.identityKeyFor(resolved);
    final resolvedMeta = _cache[resolvedKey];
    if (resolvedMeta == null) return;
    final parsed = ParsedFileName.parse(resolved.title);
    final seriesName = parsed.seriesName ?? parsed.title;
    if (seriesName.isEmpty) return;
    for (final sibling in _lastPrefetchVideos) {
      final sibKey = TmdStore.identityKeyFor(sibling);
      if (sibKey.isEmpty || sibKey == resolvedKey) continue;
      if (_cache.containsKey(sibKey)) continue;
      final sibParsed = ParsedFileName.parse(sibling.title);
      final sibSeries = sibParsed.seriesName ?? sibParsed.title;
      if (sibSeries != seriesName) continue;
      _cache[sibKey] = resolvedMeta;
      TmdStore.save(sibKey, resolvedMeta);
    }
    notifyListeners();
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

  /// Nova-style: carry a folder's TMDB metadata to every video file inside it.
  /// For a TV show folder this means every episode gets the show's poster
  /// without re-searching TMDB per file.
  void carryFolderMetaToAll(
    String folderKey,
    List<VideoItem> videos,
  ) {
    if (folderKey.isEmpty) return;
    final meta = _cache[folderKey];
    if (meta == null) return;
    for (final video in videos) {
      final key = TmdStore.identityKeyFor(video);
      if (key.isEmpty || key == folderKey) continue;
      if (_cache.containsKey(key)) continue;
      _cache[key] = meta;
      TmdStore.save(key, meta);
    }
    notifyListeners();
  }
}
