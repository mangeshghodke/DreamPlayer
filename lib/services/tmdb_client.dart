import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/tmdb_api_key.dart';
import '../models/video_item.dart';
import 'image_cache_service.dart';
import 'the_tvdb_client.dart';

String? metadataImageUrl(String? value, {int width = 780}) {
  if (value == null || value.isEmpty) return null;
  if (value.startsWith('//')) return 'https:$value';
  if (value.startsWith('http://') || value.startsWith('https://')) return value;
  return 'https://image.tmdb.org/t/p/w$width$value';
}

/// The poster URL for a cached meta, or null when there is no poster.
String? posterUrlOf(TmdMeta? meta) => meta?.movie.posterUrl(width: 185);

List<String> _stringList(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<String>()
      .where((item) => item.trim().isNotEmpty)
      .toList(growable: false);
}

/// What kind of title a matched file represents.
enum TmdKind { movie, tv }

enum MetadataProvider { tmdb, theTvdb }

extension MetadataProviderDetails on MetadataProvider {
  String get label => switch (this) {
    MetadataProvider.tmdb => 'TMDB',
    MetadataProvider.theTvdb => 'TheTVDB',
  };
}

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
    this.provider = MetadataProvider.tmdb,
    this.originalTitle,
    this.alternateTitles = const [],
  });

  final int id;
  final String title;
  final int? year;
  final String? posterPath;
  final String? backdropPath;
  final String overview;
  final double voteAverage;
  final TmdKind kind;
  final MetadataProvider provider;
  final String? originalTitle;
  final List<String> alternateTitles;

  int? get tmdbId => provider == MetadataProvider.tmdb ? id : null;

  String get providerKey => '${provider.name}:${kind.name}:$id';

  String? posterUrl({int width = 342}) =>
      metadataImageUrl(posterPath, width: width);

  String? backdropUrl({int width = 780}) =>
      metadataImageUrl(backdropPath, width: width);

  String get yearLabel => year != null ? '$year' : '';

  factory TmdMovie.fromJson(
    Map<String, dynamic> json, {
    TmdKind kind = TmdKind.movie,
  }) {
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
      provider: json['provider'] == 'theTvdb'
          ? MetadataProvider.theTvdb
          : MetadataProvider.tmdb,
      originalTitle: json[kind == TmdKind.movie ? 'original_title' : 'original_name'] as String?,
      alternateTitles: _stringList(json['alternateTitles']),
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
    'provider': provider.name,
        'originalTitle': originalTitle,
    'alternateTitles': alternateTitles,
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
    provider: json['provider'] == 'theTvdb'
        ? MetadataProvider.theTvdb
        : MetadataProvider.tmdb,
        originalTitle: json['originalTitle'] as String?,
    alternateTitles: _stringList(json['alternateTitles']),
      );
}

class TmdCastMember {
  const TmdCastMember({required this.name, this.character, this.profilePath});

  final String name;
  final String? character;
  final String? profilePath;

  String? profileUrl({int width = 185}) =>
      metadataImageUrl(profilePath, width: width);
}

class TmdTrailer {
  const TmdTrailer({required this.key,
    required this.name,
    required this.site});

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
    this.stills = const [],
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
  /// Backdrop file paths (no host) for a movie — the 16:9 stills gallery.
  /// TV shows populate this too via `images.backdrops` (harmless), but the
  /// per-episode gallery (_TmdEpisode.stills) is what episodes use instead.
  final List<String> stills;
  final String? posterPath;
  final String? backdropPath;
  final String? originalTitle;

  /// `number_of_seasons` / `number_of_episodes` from `/tv/{id}` (TV only;
  /// 0 for movies). Used to decide whether per-episode data is fetchable.
  final int numberOfSeasons;
  final int numberOfEpisodes;

  String get runtimeLabel =>
      runtimeMinutes == null ? '' : '${runtimeMinutes! ~/ 60}h ${runtimeMinutes! % 60}m';

  /// Absolute URLs for every still in [stills] (wide enough for a gallery row).
  List<String> stillUrls({int width = 780}) => stills
      .map((s) => metadataImageUrl(s, width: width))
      .whereType<String>()
      .toList();

  factory TmdDetails.fromJson(
    Map<String, dynamic> json, {
    TmdKind kind = TmdKind.movie,
  }) {
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
      stills: ((json['images'] as Map<String, dynamic>?)?['backdrops'] as List? ??
              const [])
          .whereType<Map<String, dynamic>>()
          .map((b) => b['file_path'] as String? ?? '')
          .where((p) => p.isNotEmpty)
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
      metadataImageUrl(stillPath, width: width);

  /// Absolute URLs for every still in [stills] (wide enough for a gallery row).
  List<String> stillUrls({int width = 500}) => stills
      .map((s) => metadataImageUrl(s, width: width))
      .whereType<String>()
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
      episodeNumber: (json['episode_number'] ?? json['episodeNumber'] as num?)?.toInt() ??
          0,
      name: json['name'] as String? ?? '',
      overview: json['overview'] as String? ?? '',
      stillPath: (json['still_path'] ?? json['stillPath']) as String?,
      airDate: (json['air_date'] ?? json['airDate']) as String?,
      runtimeMinutes: (json['runtime'] ?? json['runtimeMinutes'] as num?)
          ?.toInt(),
      voteAverage: (json['vote_average'] ?? json['voteAverage'] as num?)?.toDouble() ??
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
      metadataImageUrl(posterPath, width: width);

  TmdEpisode? episode(int episodeNumber) {
    for (final e in episodes) {
      if (e.episodeNumber == episodeNumber) return e;
    }
    return null;
  }

  /// Returns a copy with [replacement] swapped in for its episode number.
  TmdSeason withEpisode(TmdEpisode replacement) {
    final next = List<TmdEpisode>.of(episodes);
    final index = next.indexWhere(
      (e) => e.episodeNumber == replacement.episodeNumber,
    );
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
    this.manual = false,
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

  /// True when the user pinned this match explicitly with "Fix match"
  /// ([TmdService.setManual] / [setManualFolder]). Manual matches are sacred:
  /// automatic re-resolution (folder scans, library refreshes, prefetch)
  /// must NEVER overwrite them — only `clear()`/Remove-info removes them.
  /// Without this flag a manual fix was recalculated on the next scan and the
  /// match was silently lost (issue #11).
  final bool manual;

  TmdMeta withDetails(TmdDetails d) => TmdMeta(
      movie: movie,
      details: d,
      seasons: seasons,
      folderSeason: folderSeason,
      manual: manual,
  );

  TmdMeta withSeason(TmdSeason season) {
    final next = Map<int, TmdSeason>.of(seasons);
    next[season.seasonNumber] = season;
    return TmdMeta(
        movie: movie,
        details: details,
        seasons: next,
        folderSeason: folderSeason,
        manual: manual,
    );
  }

  TmdMeta withFolderSeason(int s) => TmdMeta(
      movie: movie,
      details: details,
      seasons: seasons,
      folderSeason: s,
      manual: manual,
  );

  Map<String, dynamic> toJson() => {
        'movie': movie.toJson(),
        'details': details == null ? null : _detailsToJson(details!),
        'seasons': seasons.values.map((s) => s.toJson()).toList(),
        if (folderSeason != null) 'folderSeason': folderSeason,
        if (manual) 'manual': true,
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
    'trailers': d.trailers
        .map((t) => {'key': t.key, 'name': t.name, 'site': t.site})
        .toList(),
    'stills': d.stills,
        'cast': d.cast
            .map(
              (c) => {
            'name': c.name, 'character': c.character, 'profilePath': c.profilePath,
          },
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
      manual: json['manual'] == true,
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
      trailers: (json['trailers'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(
            (t) => TmdTrailer(
              key: t['key'] as String? ?? '',
              name: t['name'] as String? ?? 'Trailer',
              site: t['site'] as String? ?? 'YouTube',
            ),
          )
          .where((t) => t.key.isNotEmpty)
          .toList(),
      stills: (json['stills'] as List? ?? const [])
          .whereType<String>()
          .toList(),
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
    this.hasExplicitSeason = false,

    /// When the folder/file name carries an explicit "Live Action", "Drama",
    /// or "J-Drama" keyword, this flag is set so the TMDB search can prefer
    /// the live-action adaptation over the animated version. Defaults to
    /// `false` (no preference).
    this.liveAction = false,
  });

  final String title;
  final int? year;
  final bool isEpisode;
  final String? seriesName;

  /// Season number parsed from `SxxEyy` / `x.yy` (0 for movies).
  final int season;

  /// Episode number parsed from `SxxEyy` / `x.yy` (0 for movies).
  final int episode;

  final bool hasExplicitSeason;

  int seasonWithFallback(int? folderSeason, {int? firstAvailableSeason}) {
    if (hasExplicitSeason) return season;
    if (folderSeason != null && folderSeason > 0) return folderSeason;
    if (firstAvailableSeason != null && firstAvailableSeason > 0) {
      return firstAvailableSeason;
    }
    return 1;
  }

  /// True when the parsed name contained an explicit "Live Action" / "Drama"
  /// keyword. Used by the TMDB match scorer to disambiguate
  /// `Kakegurui Twin (2021)` (live-action TV) from the original anime.
  final bool liveAction;

  /// `S02E04`-style label; empty for movies.
  String get episodeLabel => isEpisode
      ? 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
      : '';

  /// `Season 2 · Episode 4`; empty for movies.
  String get seasonEpisodeLabel =>
      isEpisode ? 'Season $season · Episode $episode' : '';

  /// Best-effort year derived from the names of the files inside a folder,
  /// used when the folder name itself carries no year. Returns the most
  /// common year found (ties → the first in listing order), or null when no
  /// name carries a year. E.g. a folder named `Kakegurui Twin-1080p BD`
  /// containing `kakegurui twin (2021) s01e01.mkv` yields the hint `2021`,
  /// letting the TMDB search pin the correct year entry instead of picking a
  /// same-titled duplicate by popularity order.
  static int? yearFromNames(Iterable<String> names) {
    final counts = <int, int>{};
    for (final name in names) {
      final year = parse(name).year;
      if (year != null) counts[year] = (counts[year] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }

  static final RegExp _yearPattern = RegExp(r'\b(18|19|20)\d{2}\b');
  static final RegExp _episodePattern = RegExp(
    r'\bS(\d{1,2})E(\d{1,2})\b',
    caseSensitive: false,
  );
  static final RegExp _episodeShortPattern = RegExp(
    r'\b(\d{1,2})x(\d{1,3})\b',
    caseSensitive: false,
  );

  /// E01 / EP01 / EP1 style — no season prefix.  season defaults to 1
  /// (most folders are single-season), episode extracted from the number.
  static final RegExp _episodeOnlyPattern = RegExp(
    r'\bEP?(\d{1,3})\b',
    caseSensitive: false,
  );

  /// [01] / [02] style — common anime fansub episode numbering in brackets.
  static final RegExp _bracketEpisodePattern =
      RegExp(r'\[(\d{1,3})\]');

  /// Bare season tag (`S02`, `S1`) — used by TV-season folder names like
  /// `HOUSE.S02.1080p...`. There's no episode number, so this is a whole
  /// season; the tag must be stripped or it pollutes the search title.
  static final RegExp _seasonOnlyPattern = RegExp(
    r'\bS(\d{1,2})\b',
    caseSensitive: false,
  );

  /// Word-style season tag (`Season 2`, `Season 03`) — used by SMB/browser
  /// season folders like "Season 2". Parsed for season detection.
  static final RegExp _seasonWordPattern = RegExp(
    r'\bSeason\s*(\d{1,2})\b',
    caseSensitive: false,
  );

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
    'hi10p', 'ma10p', 'hi444',
    // Nova-style additional garbage
    'dvdscr', 'bdrip', 'brrip', 'hdrip', 'hdlight', 'minibdrip',
    'xvid', 'divx', 'wmv', 'flv', 'f4v', 'asf', 'vob',
    'dts-x', 'dts-hd.ma', 'uhd', 'dolby',
    'hfr', 'multisubs', 'subforced', 'subforces',
    'truefrench', 'sbs', 'hsbs', '3d',
    'anaglyph', 'anaglyphe',
    // OTT / release-group tags stripped before TMDB search
    'dovi', 'dsnp', 'aptv', 'gplay', 'sic', 'zee5', 'apex', 'wrtb', 'notag', 'vff', 'qxr', 'tigor', 'fgt',
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
    name = name.replaceAll(
      RegExp(r'\b\d+\s?kbps\b', caseSensitive: false), ' ',
    );

    // Release-group suffix is conventionally attached with a dash
    // (e.g. `...x265-GROUP`). Drop everything from the last dash on. When the
    // group is followed by a site/domain (`USURY-4kHdHub.com`), the segment
    // after the final dash contains a dot — additionally drop the group token
    // sitting right before the dash when it's an all-caps release-group name
    // (`USURY`), so the search query stays title-only.
    //
    // Un-bracketed fan-sub folders use the REVERSE convention `<GROUP> - 
    // <Title>` (`VCB-Studio - Show`, `Ohys-Raws - Show`). Without handling
    // that first, the dash-cut below keeps the group token ("VCB-Studio")
    // as the whole title. Strip a leading group ONLY when it looks like a
    // release group (contains a `.`/`_`/`-` separator or is all-caps) — a
    // plain Capitalized title like `Dune - Part Two` must be preserved.
    final groupPrefixMatch = RegExp(
            r'^\s*([^\s-]+(?:[-._][^\s-]+){1,3})\s*-\s+',
            caseSensitive: false,
    ).matchAsPrefix(name);
    if (groupPrefixMatch != null) {
      final prefix = groupPrefixMatch.group(1)!;
      // Release-group guard: only strip a prefix that actually looks like a
      // group (contains a `.`/`_`/`-` separator, or is all-caps). A plain
      // Capitalized title like `Dune - Part Two` / `In the Mood for Love`
      // must be preserved (the separator check is what keeps "Dune" intact:
      // the single word has no dot/underscore/hyphen of its own).
      final looksLikeGroup = prefix.contains('-') ||
          prefix.contains('.') ||
          prefix.contains('_') ||
          (prefix.length >= 3 && prefix == prefix.toUpperCase());
      if (looksLikeGroup && prefix.length <= 24) {
        final remainder = name.substring(groupPrefixMatch.end).trim();
        if (remainder.split(RegExp(r'\s+')).length >= 2) {
          name = remainder;
        }
      }
    }

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
      } else if (!site.contains(' ')) {
        // Single-word dashed suffix with no dot is a release group (`Title -
        // VCB-Studio`). Cut it. Multi-word suffixes (`"Dune - Part Two"`,
        // `"In the Mood for Love - Part 2"`) are titles, not groups — keep them.
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
    final seasonWordMatch = _seasonWordPattern.firstMatch(name);

    var isEpisode = false;
    String? seriesName;
    var season = 0;
    var episode = 0;
    var hasExplicitSeason = false;
    if (episodeMatch != null) {
      isEpisode = true;
      hasExplicitSeason = true;
      season = int.parse(episodeMatch.group(1)!);
      episode = int.parse(episodeMatch.group(2)!);
      seriesName = name.substring(0, episodeMatch.start).trim();
      name = name.replaceAll(episodeMatch.group(0)!, ' ');
    } else if (shortEpisodeMatch != null) {
      isEpisode = true;
      hasExplicitSeason = true;
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
    } else if (seasonWordMatch != null) {
      // Word-style season folder (`Season 2`, `Season 03`): keep the season
      // number for context but drop the tag so the cleaned title stays searchable.
      season = int.parse(seasonWordMatch.group(1)!);
      seriesName = name.substring(0, seasonWordMatch.start).trim();
      name = name.replaceAll(seasonWordMatch.group(0)!, ' ');
    }

    final title = _cleanName(name);

    /// Detect an explicit "Live Action" / "Drama" keyword in either the file
    /// name or the parent folder. Stripped from the cleaned title so TMDB
    /// doesn't get confused by it, but tracked as a flag the scorer can use
    /// to disambiguate `Kakegurui Twin` (anime) from `Kakegurui Twin (2021)
    /// Live Action` (TV drama).
    bool liveAction = _looksLikeLiveAction(fileName) ||
        (parentFolderName != null && _looksLikeLiveAction(parentFolderName));

    // Fallback: when the file is just an episode number
    // (`Episode01.mkv`, `01.mkv`) or has no searchable title, fall back to
    // the parent folder's name as the series name.
    String? effectiveSeriesName = seriesName?.isNotEmpty == true ? seriesName : null;
    if (effectiveSeriesName == null &&
        parentFolderName != null &&
        parentFolderName.isNotEmpty &&
        !_hasEpisodePattern(parentFolderName) &&
        // Only inherit the parent folder as seriesName when the file itself
        // has no proper searchable title (e.g. "01.mkv", "Episode 02.mkv").
        // A standalone movie like "24 (2016).mkv" already has title="24" and
        // year=2016 — using the parent folder "24" as seriesName turns the
        // movie into a TV search and picks the wrong duplicate (2001 series).
        // The generic-title check covers the episode-only cases the fallback
        // was designed for, while year!=null blocks the movie case.
        (title.isEmpty || year == null && _isGenericTitle(title))) {
      final folderParsed = parse(parentFolderName);
      effectiveSeriesName = folderParsed.title.isNotEmpty
          ? folderParsed.title
          : _cleanName(parentFolderName);
      // If the folder carried a year (e.g. `Kakegurui Twin(2021)`), use it
      // for the TMDB search too — `search/tv` supports a first_air_date_year.
      if (year == null && folderParsed.year != null) {
        year = folderParsed.year;
      }
      // Carry the parent folder's live-action flag too.
      liveAction = liveAction || folderParsed.liveAction;
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
      hasExplicitSeason: hasExplicitSeason,
      liveAction: liveAction,
    );
  }

  /// True when [text] carries an explicit "Live Action" / "Drama" / "J-Drama"
  /// keyword that distinguishes a live-action adaptation from an animated
  /// original. Used to disambiguate TMDB results that share the same title
  /// (e.g. `Kakegurui Twin` anime vs `Kakegurui Twin (2021)` live-action).
  static bool _looksLikeLiveAction(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('live action')) return true;
    if (lower.contains('live-action')) return true;
    // "J-Drama" / "K-Drama" / "Drama" — case-insensitive; only match when
    // separated so `drama` inside another word doesn't false-positive.
    if (RegExp(
      r'(?:^|[\s\(\[\-])(?:j[\-\s]?drama|k[\-\s]?drama|drama)(?:[\s\)\]\-]|$)',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return true;
    }
    return false;
  }

  static bool _isGenericTitle(String title) {
    final t = title.trim().toLowerCase();
    if (t.isEmpty) return true;
    // Bare episode/partition labels like "episode", "ep1", "01", "part 2".
    if (RegExp(r'^(episode|ep|part|chapter)\s*\d*$').hasMatch(t)) return true;
    if (RegExp(r'^\d{1,3}$').hasMatch(t)) return true;
    if (t == 'episode' || t == 'ep') return true;
    return false;
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

    // Multi-word noise — phrases the single-word `_noise` loop can't strip
    // because the words are individually meaningful (`Live` is in many real
    // titles, `Action` too). Strip these BEFORE the single-word loop so the
    // remaining tokens can match.
    for (final phrase in const [
      'live action', 'live-action',
      'j-drama', 'j drama', 'jdrama',
      'k-drama', 'k drama', 'kdrama',
    ]) {
      cleaned = cleaned.replaceAll(
        RegExp(
          '(?<![\\w])${RegExp.escape(phrase)}(?![\\w])',
          caseSensitive: false,
        ),
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
    final cleaned = fileName.replaceAll(
      RegExp(r'[._\-\u2013\u2014\[\](){}]'),
      ' ',
    );
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

  static const Map<String, String> _seriesQueryAliases = {
    'komi san': "Komi Can't Communicate",
    'komi san wa komyushou desu': "Komi Can't Communicate",
  };

  static String canonicalSeriesQuery(String query) {
    final trimmed = query.trim();
    final normalized = trimmed
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return _seriesQueryAliases[normalized] ?? trimmed;
  }

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

  Future<List<TmdMovie>> search(
    String query, {
    int? year, TmdKind kind = TmdKind.movie,
  }) async {
    final key = await effectiveApiKey();
    if (key.isEmpty) return const [];
    final searchQuery = canonicalSeriesQuery(query);
    final endpoint = kind == TmdKind.movie ? '/search/movie' : '/search/tv';
    final params = <String, String>{
      'api_key': key,
      'query': searchQuery,
      'language': 'en-US',
      'include_adult': 'false',
      if (year != null) (kind == TmdKind.movie ? 'year' : 'first_air_date_year'): '$year',
    };
    final json = await _get('$endpoint?${_query(params)}');
    final results = json['results'] as List? ?? const [];
    final movies = results
        .whereType<Map<String, dynamic>>()
        .map((r) => TmdMovie.fromJson(r, kind: kind))
        .where((m) => m.id != 0)
        .toList();
    debugPrint(
      'TMDB search("$searchQuery") kind=$kind year=$year → ${movies.length} results: ${movies.map((m) => '${m.title}(${m.year})').join(', ')}',
    );
    return movies;
  }

  Future<TmdDetails> details(TmdMovie movie) async {
    final key = await effectiveApiKey();
    final endpoint = movie.kind == TmdKind.movie ? '/movie/${movie.id}' : '/tv/${movie.id}';
    final json = await _get(
      '$endpoint?api_key=$key&language=en-US&append_to_response=credits,videos,images',
    );
    var details = TmdDetails.fromJson(json, kind: movie.kind);
    return details;
  }

  /// Fetches a title by its TMDB id (issue #22 — "Search by TMDB ID" when
  /// title search only returns the main show). Movie and TV ids live in
  /// separate namespaces, so callers should try both kinds. Returns null on
  /// a missing id, no API key, or any HTTP failure.
  Future<TmdMovie?> byId(int id, TmdKind kind) async {
    if (id <= 0) return null;
    final key = await effectiveApiKey();
    if (key.isEmpty) return null;
    final endpoint = kind == TmdKind.movie ? '/movie/$id' : '/tv/$id';
    try {
      final json = await _get('$endpoint?api_key=$key&language=en-US');
      final movie = TmdMovie.fromJson(json, kind: kind);
      return movie.id != 0 ? movie : null;
    } catch (_) {
      return null;
    }
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
  Future<List<TmdEpisode>> seasonEpisodes(
    TmdMovie movie, int seasonNumber,
  ) async {
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
        final gallery = await episodeGallery(
          movie,
          seasonNumber,
          episodeNumber,
        );
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
    final query = canonicalSeriesQuery(
      hasSeries ? (parsed.seriesName ?? parsed.title) : parsed.title,
    );
    final year = kind == TmdKind.movie ? parsed.year : null;

    var results = await search(query, year: year, kind: kind);

    if (results.isEmpty && year != null) {
      results = await search(query, kind: kind);
    }

    // Base-query fallback — same rule resolveFolder already uses for movie
    // parts. TMDB returns 0 hits for "GIRLS und PANZER das FINALE 01" but 8
    // for the unnumbered base; _score then ranks Part N by the trailing
    // number still carried on parsed.title.
    if (results.isEmpty) {
      final base = RegExp(
        r'^(.*?)\s+\d{1,3}$',
      ).firstMatch(query.trim())?.group(1)?.trim();
      if (base != null && base.isNotEmpty && base.toLowerCase() != query.toLowerCase()) {
        results = await search(base, year: year, kind: kind);
        if (results.isEmpty) {
          results = await search(base, kind: kind);
        }
      }
    }

    if (results.isEmpty) return null;
    results.sort((a, b) => _score(b, parsed).compareTo(_score(a, parsed)));
    final best = results.first;
    final score = _score(best, parsed);
    if (score < 0.5) return null;
    return TmdMatch(best, score);
  }

  double _score(TmdMovie movie, ParsedFileName parsed) {
    final query = canonicalSeriesQuery(
      parsed.isEpisode ? (parsed.seriesName ?? parsed.title) : parsed.title,
    ).toLowerCase();
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

    // Live Action disambiguation: when the user explicitly marked the source
    // as live action (folder name "X Live Action", "X (2021) Drama"), gently
    // demote results whose title contains an anime/animation hint, so e.g.
    // `Kakegurui Twin (2021)` wins over `Kakegurui Twin (2017)`.
    if (parsed.liveAction) {
      if (RegExp(
        r'(?:^|\W)(anime|animation|animated)(?:\W|$)',
      ).hasMatch(title)) {
        score -= 0.15;
      }
    }

    // Movie-part disambiguation — same logic as _queryScore: trailing
    // "01" in "FINALE 02" should prefer "Part 2" / "Part II".
    final qStripped = query.replaceAll(RegExp(r'\[[^\]]*\]'), ' ').trim();
    final qPart = _trailingPartNumber(qStripped);
    final titlePart = _partNumberFromTitle(title);
    if (qPart != null && titlePart != null) {
      if (qPart == titlePart) {
        score += 0.45;
      } else {
        score -= 0.35;
      }
    } else if (qPart != null && titlePart == null) {
      if (!RegExp(
        r'\b(?:part|vol|movie|chapter|film)\s+\d+',
        caseSensitive: false,
      ).hasMatch(title)) {
        score -= 0.25;
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
  /// When [liveAction] is true (e.g. parsed from a folder named "X Live
  /// Action" or "X (2021) Drama"), results are gently demoted if their title
  /// contains the word "anime" / "animation" hint, since the user clearly
  /// wants the live-action adaptation, not the animated original.
  /// Best TV-or-movie match for [query]. TV wins ties with a +0.001 tieBoost
  /// (library folders are primarily shows) unless [preferMovie] is set — used
  /// when available evidence (standalone movie files, no SxxEyy anywhere)
  /// says the folder holds movies rather than a series.
  Future<TmdMatch?> bestForQuery(
    String query, {
    int? year, bool liveAction = false, bool preferMovie = false, bool hasMovieSequelPattern = false, int? desiredPart,
  }) async {
    final key = await effectiveApiKey();
    if (key.isEmpty) return null;
    final clean = canonicalSeriesQuery(query);
    if (clean.isEmpty) return null;
    final tv = await search(clean, year: year, kind: TmdKind.tv);
    final movie = await search(clean, year: year, kind: TmdKind.movie);
    debugPrint(
      'TMDB bestForQuery("$query") year=$year liveAction=$liveAction preferMovie=$preferMovie hasMovieSequelPattern=$hasMovieSequelPattern tv=${tv.length} movie=${movie.length}',
    );
    TmdMatch? best;
    void consider(TmdMovie candidate, double tieBoost) {
      final score =
          _queryScore(
            candidate,
            clean, year: year, liveAction: liveAction, desiredPart: desiredPart,
          ) +
          tieBoost;
      debugPrint(
        'TMDB   consider(${candidate.title} (${candidate.year}) kind=${candidate.kind}) score=${score.toStringAsFixed(4)} tieBoost=$tieBoost',
      );
      if (score < 0.5) return;
      if (best == null || score > best!.score) {
        best = TmdMatch(candidate, score);
      }
    }

    if (preferMovie) {
      // Movie sequel patterns (Part/Vol/Movie/Chapter N) get a strong boost
      // so "Girls und Panzer das Finale" matches the movie collection, not
      // the TV series.
      final movieBoost = hasMovieSequelPattern ? 0.15 : 0.001;
      for (final m in movie) {
        consider(m, movieBoost);
      }
      for (final m in tv) {
        consider(m, 0.0);
      }
    } else {
      for (final m in tv) {
        consider(m, 0.001);
      }
      for (final m in movie) {
        consider(m, 0.0);
      }
    }
    debugPrint(
      'TMDB bestForQuery result: ${best?.movie.title} (${best?.movie.year}) score=${best?.score.toStringAsFixed(4)}',
    );
    return best;
  }

  double _queryScore(
    TmdMovie movie, String query, {
    int? year, bool liveAction = false, int? desiredPart,
  }) {
    final q = canonicalSeriesQuery(query).toLowerCase();
    final title = movie.title.toLowerCase();
    final dist = _levenshteinDistance(q, title);
    final maxLen = q.length > title.length ? q.length : title.length;
    if (maxLen == 0) return 0.0;
    var score = (1.0 - dist / maxLen).clamp(0.0, 1.0);
    debugPrint(
      'TMDB _queryScore: q="$q" title="$title" dist=$dist maxLen=$maxLen baseScore=${score.toStringAsFixed(4)}',
    );

    // Year disambiguation: when a year is provided, strongly boost results
    // whose release year matches. This breaks ties between identically-named
    // shows (e.g. "Kakegurui Twin" 2017 vs 2022).
    if (year != null && score >= 0.5) {
      final candidateYear = movie.year;
      if (candidateYear == year) {
        score += 0.5;
        debugPrint(
          'TMDB _queryScore: year boost +0.5 (candidateYear=$candidateYear == year=$year)',
        );
      } else if (candidateYear != null) {
        score -= 0.2;
        debugPrint(
          'TMDB _queryScore: year penalty -0.2 (candidateYear=$candidateYear != year=$year)',
        );
      }
    }

    // Live Action disambiguation: when the user explicitly marked the source
    // as live action (folder name "X Live Action", "X (2021) Drama"), gently
    // demote results whose title contains an anime/original-name hint, so
    // e.g. `Kakegurui Twin (2021)` wins over `Kakegurui Twin (2017)`.
    if (liveAction && score >= 0.5) {
      if (RegExp(
        r'(?:^|\W)(anime|animation|animated)(?:\W|$)',
      ).hasMatch(title)) {
        score -= 0.15;
        debugPrint(
          'TMDB _queryScore: liveAction penalty -0.15 (anime hint in title)',
        );
      }
    }

    // Movie-part disambiguation: query "FINALE 02" should prefer
    // "Part 2" / "Part II" over "Part 1".  Extract trailing number from
    // query and Part number from title; boost on match, penalize on mismatch.
    // `desiredPart` is the trailing number from the original folder name
    // (e.g. folder "FINALE 02" → 2) which survives even when the candidate
    // query was stripped to base "FINALE".  Fall back to it when the query
    // itself has no trailing number.
    final qStripped = q.replaceAll(RegExp(r'\[[^\]]*\]'), ' ').trim();
    final qPartRaw = _trailingPartNumber(qStripped);
    final qPart = qPartRaw ?? desiredPart;
    final titlePart = _partNumberFromTitle(title);
    if (qPart != null && titlePart != null) {
      if (qPart == titlePart) {
        score += 0.45;
        debugPrint(
          'TMDB _queryScore: part match boost +0.45 (qPart=$qPart titlePart=$titlePart)',
        );
      } else {
        score -= 0.35;
        debugPrint(
          'TMDB _queryScore: part mismatch penalty -0.35 (qPart=$qPart titlePart=$titlePart)',
        );
      }
    } else if (qPart != null && titlePart == null) {
      // Query asks for a specific part but title has no Part marker (the
      // base collection entry).  Demote base so numbered parts win.
      if (RegExp(
        r'\b(?:part|vol|movie|chapter|film)\s+\d+',
        caseSensitive: false,
      ).hasMatch(title)) {
        // Title has some part marker we didn't parse — ignore.
      } else {
        score -= 0.25;
        debugPrint(
          'TMDB _queryScore: q has part $qPart but title has none — penalty -0.25',
        );
      }
    }

    debugPrint('TMDB _queryScore: final score=${score.toStringAsFixed(4)}');
    return score;
  }

  static int? _trailingPartNumber(String text) {
    final m = RegExp(r'\b(\d{1,3})\s*$').firstMatch(text.trim());
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  static int? _partNumberFromTitle(String title) {
    final m = RegExp(
      r'\bpart\s+(\d+|[ivxlcdm]+)\b',
      caseSensitive: false,
    ).firstMatch(title);
    if (m == null) return null;
    final raw = m.group(1)!.toUpperCase();
    final asInt = int.tryParse(raw);
    if (asInt != null) return asInt;
    return _romanToInt(raw);
  }

  static int? _romanToInt(String roman) {
    const values = {
      'I': 1, 'V': 5, 'X': 10, 'L': 50, 'C': 100, 'D': 500, 'M': 1000,
    };
    var total = 0;
    var prev = 0;
    for (var i = roman.length - 1; i >= 0; i--) {
      final v = values[roman[i]];
      if (v == null) return null;
      if (v < prev) {
        total -= v;
      } else {
        total += v;
      }
      prev = v;
    }
    return total > 0 ? total : null;
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
          prev[j - 1] + cost, // substitution
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
            await _client
            .getUrl(uri)
            .timeout(const Duration(seconds: 15));
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response =
            await request.close().timeout(
          const Duration(seconds: 30),
        );
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

  static String _query(Map<String, String> params) => params.entries
      .map(
        (e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
      )
      .join('&');
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
          result[entry.key] = TmdMeta.fromJson(
            (entry.value as Map).cast<String, dynamic>(),
          );
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

  // ── Suppression list (user "Remove info" intent) ─────────────────────────
  // A separate prefs list of identity keys the user explicitly dismissed via
  // "Remove info". Auto-resolution skips these keys so the same poster never
  // silently re-fetches on the next home refresh/rescan/folder open (the
  // remove-info loop the user hit on-device). Keys are un-suppressed only by
  // an explicit Fix match (setManual/setManualFolder) or by a fresh add
  // (a re-added folder gets a brand-new id → new key).

  static const String suppressedPrefsKey = 'dreamplayer.tmdbSuppressed';

  static Future<Set<String>> loadSuppressed() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(suppressedPrefsKey) ?? const []).toSet();
  }

  static Future<void> suppress(String identityKey) async {
    if (identityKey.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = [
      ...(prefs.getStringList(suppressedPrefsKey) ?? const <String>[]),
    ];
    if (list.contains(identityKey)) return;
    list.add(identityKey);
    await prefs.setStringList(suppressedPrefsKey, list);
  }

  static Future<void> unsuppress(String identityKey) async {
    if (identityKey.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = [
      ...(prefs.getStringList(suppressedPrefsKey) ?? const <String>[]),
    ];
    if (!list.remove(identityKey)) return;
    await prefs.setStringList(suppressedPrefsKey, list);
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
  final TheTvdbClient _theTvdb = TheTvdbClient();
  Map<String, TmdMeta> _cache = {};
  final Map<String, Future<TmdMeta?>> _pending = {};

  /// Identity keys the user dismissed via "Remove info". Auto-resolution
  /// (`resolve`/`resolveFolder`) returns null for these until an explicit
  /// Fix match (or a folder re-add → new key) lifts the suppression.
  final Set<String> _suppressed = {};

  /// In-flight season/episode detail fetches (dedup only; these return
  /// non-[TmdMeta] types so they can't share the [_pending] future map).
  final Set<String> _pendingDetail = {};
  bool _loaded = false;

  /// Last prefetch list — used by [_staggerPrefetch] to carry resolved meta
  /// to sibling files in the same series after each individual resolve.
  List<VideoItem> _lastPrefetchVideos = const [];

  bool get loaded => _loaded;

  void refreshTheTvdbCredentials() {
    _theTvdb.invalidateToken();
  }

  Future<bool> get _useTheTvdbFallback async {
    try {
      return await TheTvdbClient.isFallbackEnabled() &&
          await _theTvdb.isConfiguredAsync;
    } catch (_) {
      return false;
    }
  }

  static int? _trailingPartNumber(String folderName) {
    final stripped = folderName.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    final m = RegExp(r'\b(\d{1,3})\s*$').firstMatch(stripped.trim());
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  static int? _partNumberFromTitle(String title) {
    final m = RegExp(
      r'\bpart\s+(\d+|[ivxlcdm]+)\b',
      caseSensitive: false,
    ).firstMatch(title);
    if (m == null) return null;
    final raw = m.group(1)!.toUpperCase();
    final asInt = int.tryParse(raw);
    if (asInt != null) return asInt;
    return _romanToInt(raw);
  }

  static int? _romanToInt(String roman) {
    const values = {
      'I': 1, 'V': 5, 'X': 10, 'L': 50, 'C': 100, 'D': 500, 'M': 1000,
    };
    var total = 0;
    var prev = 0;
    for (var i = roman.length - 1; i >= 0; i--) {
      final v = values[roman[i]];
      if (v == null) return null;
      if (v < prev) {
        total -= v;
      } else {
        total += v;
      }
      prev = v;
    }
    return total > 0 ? total : null;
  }

  TmdMeta? metaFor(String identityKey) => _cache[identityKey];

  bool isResolving(String identityKey) => _pending.containsKey(identityKey);

  bool isSuppressed(String identityKey) => _suppressed.contains(identityKey);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _cache = await TmdStore.loadAll();
    _suppressed
      ..clear()
      ..addAll(await TmdStore.loadSuppressed());
    await _loadPersistedSeasonNames();
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
    // User dismissed this entry via "Remove info" — do not silently re-fetch
    // it on the next prefetch/rescan/folder open. Only an explicit Fix match
    // clears the suppression.
    if (_suppressed.contains(identityKey)) return null;
    final parsed = ParsedFileName.parse(
      video.title,
      parentFolderName: parentFolderName,
    );
    if (parsed.title.isEmpty) return null;

    final cached = _cache[identityKey];
    if (cached != null) {
      // A user-pinned "Fix match" entry is sacred: never re-resolve or drop
      // it based on stale-cache heuristics (issue #11). Only `clear()` removes
      // a manual match.
      if (cached.manual) return cached;
      // Stale-cache guard: the old parentFolderName fallback used the SMB
      // parent folder ("24") as seriesName for files like "24 (2016).mkv",
      // caching the 2001 TV series under the file's key. That wrong entry
      // would be returned forever via the early `return cached` above and the
      // prefetch's `service.metaFor(key) != null` skip. Detect the mismatch
      // (wrong kind or year) and re-resolve instead of returning stale data.
      final hasSeries = parsed.isEpisode ||
          (parsed.seriesName?.isNotEmpty ?? false);
      final expectedKind = hasSeries ? TmdKind.tv : TmdKind.movie;
      final isStaleKind = cached.movie.kind != expectedKind;
      final isStaleYear = parsed.year != null &&
          cached.movie.year != null &&
          cached.movie.year != parsed.year;
      if (!isStaleKind && !isStaleYear) {
        return cached;
      }
      // Stale — drop it so _resolveNow overwrites with the correct match.
      _cache.remove(identityKey);
      try {
        await TmdStore.remove(identityKey);
      } catch (_) {}
    }
    final inFlight = _pending[identityKey];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _resolveNow(identityKey, parsed);
    _pending[identityKey] = future;
    try {
      return await future;
    } finally {
      _pending.remove(identityKey);
      notifyListeners();
    }
  }

  Future<TmdMeta?> _resolveNow(
    String identityKey, ParsedFileName parsed,
  ) async {
    TmdMatch? match;
    try {
      match = await _api.bestMatch(parsed);
    } catch (_) {}
    if (match == null && await _useTheTvdbFallback) {
      try {
        match = await _theTvdb.bestMatch(parsed);
      } catch (_) {}
    }
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
  ///
  /// [yearHint] supplies a year the folder name itself doesn't carry — e.g.
  /// derived via [ParsedFileName.yearFromNames] from the files inside the
  /// folder. When parsing [folderName] yields no year, [yearHint] is used to
  /// disambiguate same-titled entries that differ only by release year (TMDB
  /// returns both, sorted by popularity — which can pick the wrong duplicate).
  ///
  /// [fileNames] lists the folder's file names (when the caller has them
  /// cheaply, e.g. after a directory listing). Used as additional search
  /// queries when the folder name doesn't match: a video filename that carries
  /// `SxxEyy` (or a clean title) is the most reliable source for TMDB, and a
  /// folder name full of release-group tags ([VCB-Studio] / [Hi10p_1080p])
  /// can be useless for search even after cleaning (issue #11).
  Future<TmdMeta?> resolveFolder(
    String metadataKey,
    String folderName, {
    int? yearHint,
    List<String>? fileNames,
  }) async {
    await ensureLoaded();
    // User dismissed this folder via "Remove info" — do not silently
    // re-match on the next home refresh / folder re-open (issue #11).
    if (_suppressed.contains(metadataKey)) return null;
    final cached = _cache[metadataKey];
    debugPrint(
      'TMDB resolveFolder("$metadataKey","$folderName") cached=$cached keepSeasons=${cached?.seasons[cached.folderSeason ?? -1]?.posterPath != null}',
    );
    // A user-pinned "Fix match" entry is sacred: re-resolution (home refresh,
    // library rescan, prefetch) must NEVER overwrite it — the old path
    // recalculated the match from the folder name every call and silently
    // replaced or dropped the manual fix (issue #11). Only `clear()` removes it.
    if (cached != null && cached.manual) return cached;
    // Return cache when it already has both folderSeason AND the season poster
    // for that season. A stale cache with folderSeason set but no seasons
    // entry (e.g. from a build that didn't fetch the season poster, or where
    // the season fetch failed) would make the home card fall back to the
    // show's main poster — so refill the season data here. seasonFor() itself
    // short-circuits when its own cache already has a poster, so this is one
    // extra request only when the season cache is actually incomplete.
    //
    // When multiple auto-expanded folders share a metadataKey (via
    // SeriesGroup), the cache may hold a folderSeason from a DIFFERENT
    // folder (e.g. "Final" → Season 5 overwrites "Strike the Blood" →
    // Season 1). Detect staleness by checking if the cached season name
    // is consistent with the current folder name.
    if (cached != null && cached.folderSeason != null) {
      final names = _seasonNamesCache[_seasonKeyForMovie(cached.movie)];
      if (names != null) {
        final cachedSeasonName = names[cached.folderSeason];
        if (cachedSeasonName != null) {
          final q = folderName
              .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
              .toLowerCase()
              .trim();
          final sLower = cachedSeasonName.toLowerCase().trim();
          // The staleness check is only valid when the folder name looks like
          // a season subfolder (e.g. "Strike the Blood Final", "Season 2").
          // For a top-level show folder like "House" the folder name is the
          // show title, not the season name — "House" will never contain
          // "Season 2". Only run the check when the folder name contains a
          // season-like pattern (S01, Season N, roman numeral) so single-show
          // folders aren't incorrectly wiped.
          final hasSeasonTag = RegExp(
            r'\bs\d{1,2}\b|\bseason\s+\d+|\b(?:I{1,3}|IV|V|VI{0,3}|IX|X)\b',
            caseSensitive: false,
          ).hasMatch(q);
          if (hasSeasonTag) {
            final matches = q.contains(sLower) || sLower.contains(q);
            if (!matches) {
              _cache.remove(metadataKey);
              TmdStore.remove(metadataKey);
            } else if (cached.seasons[cached.folderSeason]?.posterPath != null ||
                cached.movie.kind != TmdKind.tv) {
              return cached;
            }
          } else if (cached.seasons[cached.folderSeason]?.posterPath != null ||
              cached.movie.kind != TmdKind.tv) {
            return cached;
          }
        } else if (cached.seasons[cached.folderSeason]?.posterPath != null ||
            cached.movie.kind != TmdKind.tv) {
          return cached;
        }
      } else {
        // Season names not cached yet (in-memory only, lost on restart) —
        // can't verify folderSeason. Trust the cached entry rather than
        // deleting it: the metadata was correct when first resolved, and
        // destroying it here loses the poster/title/seasons on every offline
        // restart. The staleness check only runs when season names ARE
        // available (same session); when they aren't, just return what we have.
        return cached;
      }
    }
    // Movie-part staleness: a folder like "FINALE 02" that cached as
    // "Girls und Panzer das Finale: Part I" is stale after the fix that
    // made movie parts preserve their trailing number.  Detect and drop
    // so the next candidate pass (numbered query first) can pick the
    // correct part.
    // Stale movie-part detection — keep the old poster visible until the
    // replacement arrives.  Just log here; don't clear _cache yet or the
    // grid will flash to placeholder while the network fetch runs.
    if (cached != null && cached.movie.kind == TmdKind.movie) {
      final folderPart = _trailingPartNumber(folderName);
      final cachedPart = _partNumberFromTitle(cached.movie.title);
      if (folderPart != null && cachedPart != null && folderPart != cachedPart) {
        debugPrint(
          'TMDB resolveFolder: stale movie-part cache "$metadataKey" (folder part $folderPart vs cached "${cached.movie.title}" part $cachedPart) — will re-resolve, keeping stale poster until fresh',
        );
      } else if (folderPart != null && cachedPart == null) {
        final hasAnyPartMarker = RegExp(
          r'\b(?:part|vol(?:ume)?|movie|chapter|film)\s+\d+',
          caseSensitive: false,
        ).hasMatch(cached.movie.title);
        if (!hasAnyPartMarker) {
          debugPrint(
            'TMDB resolveFolder: movie-part folder "$metadataKey" cached as base title without part marker — will re-resolve, keeping stale poster until fresh',
          );
        }
      }
    }

    final inFlight = _pending[metadataKey];
    if (inFlight != null) return inFlight;

    final parsed = ParsedFileName.parse(folderName);
    debugPrint(
      'TMDB resolveFolder parsed: title="${parsed.title}" year=${parsed.year} season=${parsed.season} episode=${parsed.episode} isEpisode=${parsed.isEpisode} seriesName=${parsed.seriesName}',
    );
    if (parsed.title.isEmpty && (fileNames == null || fileNames.isEmpty)) {
      return null;
    }

    final year = parsed.year ?? yearHint;
    // Candidate search queries, tried in order of reliability. The folder's
    // own cleaned title first, then queries derived from the files inside
    // (an episode filename's seriesName, or standalone movie titles). File
    // evidence also flips the TV/movie tie-break: a folder of standalone
    // movies (no SxxEyy anywhere) should match a movie before a TV show.
    final candidates = <({String q, int? y})>[];
    // For episode filenames, search by series name (not the full title which
    // includes the episode name and returns 0 TMDB results).
    final searchTitle = parsed.isEpisode && parsed.seriesName != null
        ? parsed.seriesName!
        : parsed.title;
    final fileEvidence = _queriesFromFileNames(fileNames ?? const []);
    // Use the year from file names as a disambiguation hint when the folder
    // name has no year (e.g. folder "Kakegurui Twin" → file "Kakegurui Twin(2021) s01e01.mkv" → year=2021).
    final effectiveYear = year ?? fileEvidence.yearHint;
    if (searchTitle.isNotEmpty) {
      candidates.add((q: searchTitle, y: effectiveYear));
    }
    for (final fq in fileEvidence.queries) {
      if (candidates.every((c) => c.q.toLowerCase() != fq.toLowerCase())) {
        candidates.add((q: fq, y: effectiveYear));
      }
    }
    final preferMovie = !parsed.isEpisode && !fileEvidence.hasEpisodes;
    // A folder of movie *parts* ("GIRLS und PANZER das FINALE 01") — try
    // the exact numbered query first so each part resolves to its own
    // movie (01→Part I, 02→Part II, etc.).  The stripped base
    // ("GIRLS und PANZER das FINALE") is kept as a fallback for cases
    // where the numbered query would match a wrong OVA entry.
    if (preferMovie) {
      final baseCandidates = <({String q, int? y})>[];
      for (final c in List.of(candidates)) {
        final m = RegExp(r'^(.*?)\s+\d{1,3}$').firstMatch(c.q.trim());
        final base = m?.group(1);
        if (base != null &&
            base.isNotEmpty &&
            candidates.every(
              (c2) => c2.q.toLowerCase() != base.toLowerCase(),
            )) {
          baseCandidates.add((q: base, y: c.y));
        }
      }
      if (baseCandidates.isNotEmpty) {
        candidates.addAll(baseCandidates);
      }
    }
    // Detect movie sequel patterns: "Part 1", "Vol 2", "Movie 3", "Chapter 1".
    // These are standalone movie files, not episodes — boost movie preference.
    final hasMovieSequelPattern = fileEvidence.hasMovieSequelPattern;

    final desiredPart = _trailingPartNumber(folderName);
    final future = _resolveFolderCandidates(
      metadataKey,
      candidates,
        preferMovie: preferMovie,
        liveAction: parsed.liveAction,
        folderName: folderName,
        hasMovieSequelPattern: hasMovieSequelPattern,
        desiredPart: desiredPart,
    );
    _pending[metadataKey] = future;
    try {
      final meta = await future;
      // Inline-fill the season poster so the home card renders the season
      // artwork on its very first paint instead of falling back to the show's
      // main poster. seasonFor() is awaited inside this critical section so
      // the meta returned from resolveFolder() already has seasons[folderSeason].
      if (meta != null &&
          meta.folderSeason != null &&
          meta.movie.kind == TmdKind.tv &&
          meta.seasons[meta.folderSeason]?.posterPath == null) {
        await seasonFor(metadataKey, meta.folderSeason!);
        return _cache[metadataKey];
      }
      return meta;
    } finally {
      _pending.remove(metadataKey);
      notifyListeners();
    }
  }

  /// Pure helper: derives candidate TMDB queries from the names of the files
  /// inside a folder. Episode files contribute their show name; standalone
  /// files contribute their title. Returns up to [maxQueries] unique queries
  /// (most common first) plus whether any file looked like an episode, and
  /// the most common year found in file names (for year disambiguation).
  static ({
    List<String> queries, bool hasEpisodes, bool hasMovieSequelPattern, int? yearHint,
  })
  _queriesFromFileNames(Iterable<String> names, {int maxQueries = 4}) {
    final counts = <String, int>{};
    var hasEpisodes = false;
    var hasMovieSequelPattern = false;
    final yearCounts = <int, int>{};
    for (final name in names) {
      final p = ParsedFileName.parse(name);
      // Season-only folder names (e.g. "s02", "Season 3") are a strong TV
      // signal even without episode markers — treat them as episode evidence
      // so the folder resolves as a TV show instead of a same-named movie.
      if (p.season > 0 && !p.isEpisode) hasEpisodes = true;
      final q =
          (p.isEpisode ? (p.seriesName ?? p.title) : p.title)
          .trim()
          .toLowerCase();
      if (q.isEmpty) continue;
      if (p.isEpisode) hasEpisodes = true;
      // Detect movie sequel patterns: "Part 1", "Vol 2", "Movie 3", "Chapter 1".
      if (RegExp(
        r'\b(?:part|vol(?:ume)?|movie|chapter|film)\s+\d+\b',
        caseSensitive: false,
      ).hasMatch(name)) {
        hasMovieSequelPattern = true;
      }
      if (p.year != null) yearCounts[p.year!] = (yearCounts[p.year!] ?? 0) + 1;
      counts[q] = (counts[q] ?? 0) + 1;
    }
    final ranked = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final queries = <String>[];
    for (final e in ranked) {
      if (queries.length >= maxQueries) break;
      queries.add(e.key);
    }
    // Pick the most common year from file names as a hint for disambiguation.
    int? fileYearHint;
    if (yearCounts.isNotEmpty) {
      final sorted = yearCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      fileYearHint = sorted.first.key;
    }
    return (
      queries: queries, hasEpisodes: hasEpisodes, hasMovieSequelPattern: hasMovieSequelPattern, yearHint: fileYearHint,
    );
  }

  /// Runs [_resolveFolderNow] across [candidates] in order, returning the
  /// first that produces a match.
  Future<TmdMeta?> _resolveFolderCandidates(
    String metadataKey,
    List<({String q, int? y})> candidates, {
    required bool preferMovie,
    bool liveAction = false,
    String? folderName,
    bool hasMovieSequelPattern = false,
    int? desiredPart,
  }) async {
    TmdMeta? last;
    for (final c in candidates) {
      last = await _resolveFolderNow(
        metadataKey,
        c.q, c.y,
          liveAction: liveAction,
          folderName: folderName,
          preferMovie: preferMovie,
          hasMovieSequelPattern: hasMovieSequelPattern,
          desiredPart: desiredPart,
      );
      if (last != null) return last;
      // No match for this query — move on to the next candidate query.
    }
    return last;
  }

  String _seasonKey(int showId, MetadataProvider provider) =>
      '${provider.name}:tv:$showId';

  String _seasonKeyForMovie(TmdMovie movie) => movie.providerKey;

  int? matchFolderToSeason(
    String folderName, int showId, {
    MetadataProvider provider = MetadataProvider.tmdb,
  }) {
    final names = _seasonNamesCache[_seasonKey(showId, provider)];
    if (names == null || names.isEmpty) return null;
    return _matchSeasonFromFolder(folderName, names);
  }

  bool hasSeasonNames(
    int showId, {
    MetadataProvider provider = MetadataProvider.tmdb,
  }) => _seasonNamesCache[_seasonKey(showId, provider)]?.isNotEmpty ?? false;

  Map<int, String> seasonNameMapForDebug(
    int showId, {
    MetadataProvider provider = MetadataProvider.tmdb,
  }) => _seasonNamesCache[_seasonKey(showId, provider)] ?? {};

  Future<void> fetchSeasonNames(TmdMovie? movie) async {
    if (movie == null || movie.kind != TmdKind.tv || movie.id <= 0) return;
    try {
      final names = movie.provider == MetadataProvider.theTvdb
          ? await _theTvdb.seasonNames(movie)
          : await _api.seasonNames(movie);
    if (names.isNotEmpty) {
        _seasonNamesCache[_seasonKeyForMovie(movie)] = names;
      _savePersistedSeasonNames();
    }
  } catch (_) {}
  }

  Future<Map<int, String>> seasonNameMapFor(String identityKey) async {
    await ensureLoaded();
    final meta = _cache[identityKey];
    if (meta == null || meta.movie.kind != TmdKind.tv) return const {};
    final key = _seasonKeyForMovie(meta.movie);
    final cached = _seasonNamesCache[key];
    if (cached != null) return cached;
    try {
      final names = meta.movie.provider == MetadataProvider.theTvdb
          ? await _theTvdb.seasonNames(meta.movie)
          : await _api.seasonNames(meta.movie);
    if (names.isNotEmpty) {
        _seasonNamesCache[key] = names;
      _savePersistedSeasonNames();
    }
    return names;
  } catch (_) {
      return const {};
    }
  }

  final Map<String, Map<int, String>> _seasonNamesCache = {};

  /// SharedPreferences key for persisted season names.
  static const _seasonNamesPrefsKey = 'dreamplayer.seasonNames';

  /// Load persisted season names into the in-memory cache.
  Future<void> _loadPersistedSeasonNames() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_seasonNamesPrefsKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        final parts = entry.key.split(':');
        final key = parts.length >= 3
            ? entry.key
            : parts.length == 2
            ? '${parts[0]}:tv:${parts[1]}'
            : '${MetadataProvider.tmdb.name}:tv:${entry.key}';
        final names = (entry.value as Map<String, dynamic>).map(
          (k, v) => MapEntry(int.tryParse(k) ?? 0, v as String? ?? ''),
        );
        if (names.isNotEmpty) _seasonNamesCache[key] = names;
      }
    } catch (_) {}
  }

  /// Persist the full season names map to SharedPreferences.
  Future<void> _savePersistedSeasonNames() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = _seasonNamesCache.map(
        (showId, names) => MapEntry(
          showId.toString(),
          names.map((k, v) => MapEntry(k.toString(), v)),
        ),
      );
      await prefs.setString(_seasonNamesPrefsKey, jsonEncode(encoded));
    } catch (_) {}
  }

  /// Seed the in-memory season-names cache from persisted [TmdMeta.seasons]
  /// so that [matchFolderToSeason] works offline (after a restart where
  /// the in-memory cache is empty but the seasons data was saved to prefs).
  void seedSeasonNamesFromCache() {
    for (final entry in _cache.entries) {
      final meta = entry.value;
      if (meta.movie.kind != TmdKind.tv || meta.seasons.isEmpty) continue;
      final showId = _seasonKeyForMovie(meta.movie);
      if (_seasonNamesCache.containsKey(showId)) continue;
      final names = <int, String>{};
      for (final sEntry in meta.seasons.entries) {
        final name = sEntry.value.name.trim();
        if (name.isNotEmpty) names[sEntry.key] = name;
      }
      if (names.isNotEmpty) _seasonNamesCache[showId] = names;
    }
  }

  Future<TmdMeta?> _resolveFolderNow(
      String metadataKey, String query, int? year, {
    bool liveAction = false, String? folderName, bool preferMovie = false, bool hasMovieSequelPattern = false, int? desiredPart,
  }) async {
    debugPrint(
      'TMDB _resolveFolderNow key="$metadataKey" query="$query" year=$year liveAction=$liveAction folderName="$folderName" preferMovie=$preferMovie desiredPart=$desiredPart',
    );
    TmdMatch? match;
    try {
      match = await _api.bestForQuery(
        query,
        year: year, liveAction: liveAction, preferMovie: preferMovie, hasMovieSequelPattern: hasMovieSequelPattern, desiredPart: desiredPart,
      );
    } catch (_) {}
    if (match == null && await _useTheTvdbFallback) {
      try {
        match = await _theTvdb.bestForQuery(
          query,
          year: year,
          liveAction: liveAction,
          preferMovie: preferMovie,
          hasMovieSequelPattern: hasMovieSequelPattern,
          desiredPart: desiredPart,
        );
      } catch (_) {}
    }
    if (match == null) return null;

    // Check if the folder name matches a season name on TMDB.
    // e.g. "Strike the Blood Final" → Season 5 "Strike the Blood Final".
    // Use the CLEANED query (ParsedFileName.parse title) which preserves
    // season indicators ("Final", "II", "III") but strips quality/noise tags
    // (1080p, WEB-DL, etc.) so exact/containment matching works correctly.
    int? folderSeason;
    if (match.movie.kind == TmdKind.tv) {
      var names = <int, String>{};
      try {
        names = match.movie.provider == MetadataProvider.theTvdb
            ? await _theTvdb.seasonNames(match.movie)
            : await _api.seasonNames(match.movie);
      } catch (_) {}
      _seasonNamesCache[_seasonKeyForMovie(match.movie)] = names;
      _savePersistedSeasonNames();
      // Use the original folder name for season matching — the cleaned
      // query strips the season tag (e.g. House S02 → House) and would
      // miss the fast-path ParsedFileName season check.
      final seasonQuery = (folderName != null && folderName.isNotEmpty) ? folderName : query;
      folderSeason = _matchSeasonFromFolder(seasonQuery, names);
      debugPrint(
        'TMDB _resolveFolderNow $metadataKey matchId=${match.movie.id} seasons=$names folderSeason=$folderSeason',
      );
    }

    // When multiple auto-expanded folders share the same metadataKey
    // (via SeriesGroup), each folder's resolution overwrites the cache.
    // The first folder that matched a season "owns" this key — don't let
    // a later folder's resolution replace its folderSeason.
    final existing = _cache[metadataKey];
    if (existing != null &&
        existing.folderSeason != null &&
        existing.movie.providerKey == match.movie.providerKey) {
      return existing;
    }

    // Preserve previously fetched seasons from _fetchSeasonData when
    // re-resolving the same show (e.g. home screen refresh). The new
    // resolution only provides folderSeason; _fetchSeasonData adds the
    // full per-season data (episodes, posters) later.
    final mergedSeasons = <int, TmdSeason>{};
    if (existing != null &&
        existing.movie.providerKey == match.movie.providerKey) {
      mergedSeasons.addAll(existing.seasons);
    }

    final meta = TmdMeta(
      movie: match.movie,
      details:
          existing != null &&
              existing.movie.providerKey == match.movie.providerKey
          ? existing.details
          : null,
      seasons: mergedSeasons,
      folderSeason: folderSeason,
      manual: false,
    );
    _cache[metadataKey] = meta;
    await TmdStore.save(metadataKey, meta);
    // Prefetch images to the permanent disk cache so they're available offline.
    ImageCacheService.instance.prefetchImages(
      posterUrl: match.movie.posterUrl(),
      backdropUrl: match.movie.backdropUrl(),
    );
    return meta;
  }

  /// Checks if [folderName] matches any season name in [seasonNames].
  /// Returns the matched season number, or null if no match.
  int? _matchSeasonFromFolder(String folderName, Map<int, String> seasonNames) {
    return matchFolderToSeasonName(folderName, seasonNames);
  }

  /// Pure matcher: resolves [folderName] to a season number given the show's
  /// [seasonNames]. No API calls — testable without an HTTP client.
  ///
  /// Matching strategy:
  /// 1. Release-group / language noise (`[VCB-Studio]`, `[SubsPlease]`) is
  ///    stripped from the folder name — it is not part of any season name, and
  ///    it breaks the exact/containment match below (which is how
  ///    "[VCB-Studio] Strike the Blood" used to land on Season 2 — see 2026-09
  ///    regression below).
  /// 2. Exact match (case-insensitive): "Strike the Blood Final" == "Strike the Blood Final"
  /// 3. Containment: the LONGEST season name contained in (or containing) the
  ///    query wins — "Strike the Blood II" is more specific than "Strike the
  ///    Blood". There is no `sName.length > q.length` gate here: a folder
  ///    "Strike the Blood 1080p" used to fall through to word-overlap and be
  ///    mis-matched to Season 2 (see below).
  /// 4. Suffix (issue #22): the folder name is a word-boundary suffix of a
  ///    season name — "Railgun S" → "A Certain Scientific Railgun S".
  /// 5. Word overlap (fallback when neither name contains the other): all
  ///    words of the shorter name appear in the longer.
  ///
  /// 2026-09 regression fixed here: the old matcher dropped ≤2-char tokens
  /// (`ii`, `iv`) before word-overlap, which made Season 1 "Strike the Blood",
  /// Season 2 "Strike the Blood II" and Season 4 "Strike the Blood IV" all
  /// reduce to the word set {strike, the, blood}. The score then tied on the
  /// name-length term and favored the LONGER name — Season 2. So a folder
  /// "[VCB-Studio] Strike the Blood" displayed as "Strike the Blood II" on the
  /// home card. The bracket-strip + containment passes resolve Season 1 (and
  /// every real roman-suffix folder) deterministically before overlap runs.
  static int? matchFolderToSeasonName(
      String folderName, Map<int, String> seasonNames,
  ) {
    if (folderName.isEmpty || seasonNames.isEmpty) return null;

    // Fast path: explicit Sxx or Season N tag in the folder name
    // (e.g. "HOUSE.S02.1080p..." → 2, "House Season 3" → 3).
    final parsed = ParsedFileName.parse(folderName);
    if (parsed.season > 0 && seasonNames.containsKey(parsed.season)) {
      return parsed.season;
    }
    final sMatch = RegExp(
      r'\bS(\d{1,2})\b',
      caseSensitive: false,
    ).firstMatch(folderName);
    if (sMatch != null) {
      final s = int.tryParse(sMatch.group(1)!);
      if (s != null && seasonNames.containsKey(s)) return s;
    }
    final seasonMatch = RegExp(
      r'\bSeason\s+(\d{1,2})\b',
      caseSensitive: false,
    ).firstMatch(folderName);
    if (seasonMatch != null) {
      final s = int.tryParse(seasonMatch.group(1)!);
      if (s != null && seasonNames.containsKey(s)) return s;
    }

    final q = folderName
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
        .toLowerCase()
        .trim();
    if (q.isEmpty) return null;

    final entries = seasonNames.entries.toList();

    // Exact match — always wins.
    for (final entry in entries) {
      final sName = entry.value.toLowerCase().trim();
      if (sName.isEmpty) continue;
      if (q == sName) return entry.key;
    }

    // Containment — longest matching season name wins, but only when the rest
    // of the folder name is release noise (resolution/source/codec/group
    // tags). A folder like "Strike the Blood Kieta Seisou Hen" contains the
    // string "Strike the Blood" yet has extra real content beyond any season
    // title — it is NOT a season folder and must not masquerade as Season 1
    // (it should render as a gradient card, not steal Season 1's poster).
    int? bestSeason;
    var bestNameLen = 0;
    for (final entry in entries) {
      final sName = entry.value.toLowerCase().trim();
      if (sName.isEmpty) continue;
      final qIdx = q.indexOf(sName);
      if (qIdx >= 0) {
        // Folder name contains the whole season name — accept only if the
        // leftover words are all release noise.
        final leftover = q
            .replaceRange(qIdx, qIdx + sName.length, ' ')
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty);
        if (leftover.every(_isSeasonNoiseToken)) {
          if (sName.length > bestNameLen) {
            bestNameLen = sName.length;
            bestSeason = entry.key;
          }
        }
      } else if (sName.contains(q)) {
        // Folder name is a strict prefix of a season name. Accept only if the
        // season-name remainder is noise-free glue. (The exact pass already
        // catches "Strike the Blood" = Season 1; this is a rare fallback.)
        final sIdx = sName.indexOf(q);
        final leftover = sName
            .replaceRange(sIdx, sIdx + q.length, ' ')
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty);
        if (leftover.every(_isSeasonNoiseToken)) {
          if (sName.length > bestNameLen) {
            bestNameLen = sName.length;
            bestSeason = entry.key;
          }
        }
      }
    }
    if (bestSeason != null) return bestSeason;

    // Suffix — the folder name is a word-boundary suffix of the season name
    // (issue #22: "Railgun S" → "A Certain Scientific Railgun S",
    // "Railgun T" → "… Railgun T"). Heavy release noise (`1080p`, `BluRay`)
    // is stripped from the folder end first; short tokens (`S`, `T`, `II`)
    // are never stripped because they ARE the season letter. Longest season
    // name wins when several seasons share the same ending.
    final qBase = _stripTrailingHeavyNoise(q);
    int? suffixSeason;
    var bestSuffixLen = 0;
    for (final entry in entries) {
      final sName = entry.value.toLowerCase().trim();
      if (sName.isEmpty) continue;
      if (sName != qBase && !sName.endsWith(' $qBase')) continue;
      if (sName.length > bestSuffixLen) {
        bestSuffixLen = sName.length;
        suffixSeason = entry.key;
      }
    }
    if (suffixSeason != null) return suffixSeason;

    // Word overlap — every word of the shorter name must appear in the longer,
    // AND any extra words in the longer name must all be release noise. This
    // preserves the old behavior for pure-name folders while disqualifying
    // folders whose extra words are real content ("Kieta Seisou Hen" behind
    // "Strike the Blood" cannot claim any season).
    int? overlapSeason;
    var bestScore = 0;
    for (final entry in entries) {
      final sName = entry.value.toLowerCase().trim();
      if (sName.isEmpty) continue;
      final qWords = q
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();
      final sWords = sName
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();
      if (qWords.isEmpty || sWords.isEmpty) continue;
      final shorter = qWords.length <= sWords.length ? qWords : sWords;
      final longer = qWords.length <= sWords.length ? sWords : qWords;
      if (!shorter.every(longer.contains)) continue;
      final remainingShorter = shorter.toList();
      final extra = <String>[];
      for (final w in longer) {
        final i = remainingShorter.indexOf(w);
        if (i >= 0) {
          remainingShorter.removeAt(i);
        } else {
          extra.add(w);
        }
      }
      if (extra.any((w) => !_isSeasonNoiseToken(w))) continue;
      final score = shorter.length * 10 + sName.length;
      if (score > bestScore) {
        bestScore = score;
        overlapSeason = entry.key;
      }
    }
    return overlapSeason;
  }

  /// Whether one lowercased token is release noise that may legitimately
  /// surround a season name in a folder title (resolution/source/codec/audio
  /// tags, glue words, group names, years, plain numbers). Everything else is
  /// treated as real title content — so "Kieta" / "Seisou" / "Hen" disqualify
  /// a folder from being a season folder and it keeps its gradient card.
  static bool _isSeasonNoiseToken(String w) {
    if (w.isEmpty) return false;
    if (RegExp(r'^\d{1,4}$').hasMatch(w)) return true; // 1080, 2021, 60, 5
    if (w.length <= 2) return true;                    // glue + compact tags
    const noise = <String>{
      'web', 'webdl', 'webrip', 'webhd', 'bluray', 'brrip', 'bdrip',
      'hdtv', 'dvdr', 'dvd', 'remux', 'proper', 'repack', 'internal',
      'limited', 'complete', 'extended', 'uncut', 'retail', 'rip',
      '480p', '576p', '720p', '1080p', '2160p', '4320p',
      'x264', 'x265', 'h264', 'h265', 'avc', 'hevc', 'av1', 'vp9',
      '10bit', '8bit', 'hdr', 'hdr10', 'sdr', 'atmos', 'truehd', 'dts',
      'eac3', 'ac3', 'aac', 'flac', 'opus', 'pcm', 'mp3', 'multi', 'dual',
      'dubbed', 'subbed', 'subs', 'eng', 'jap', 'jpn', 'english', 'japanese',
      'romaji', 'collection', 'edition', 'season', 'fansub', 'vcb', 'studio',
      'raws', 'disc', 'blu', 'ray',
    };
    return noise.contains(w);
  }

  /// Drops trailing heavy release noise from an already-lowercased query so
  /// "railgun s - 1080p" can still suffix-match a season name. Never strips
  /// short tokens (`s`, `t`, `ii`) or pure punctuation glued mid-name — only
  /// trailing noise longer than 2 chars, or trailing punctuation/numbers that
  /// cannot be part of a season letter suffix.
  static String _stripTrailingHeavyNoise(String input) {
    final words = input
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    while (words.length > 1) {
      final last = words.last;
      final punct = RegExp(r'^[^\p{L}\p{N}]+$', unicode: true).hasMatch(last);
      final heavyNoise = last.length > 2 && _isSeasonNoiseToken(last);
      if (!punct && !heavyNoise) break;
      words.removeLast();
    }
    return words.join(' ');
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

  Future<TmdDetails?> detailsForMovie(TmdMovie movie) async {
    try {
      return movie.provider == MetadataProvider.theTvdb
          ? await _theTvdb.details(movie)
          : await _api.details(movie);
    } catch (_) {
      return null;
    }
  }

  /// Fetches full details (synopsis, cast, runtime) for a matched video.
  Future<TmdDetails?> detailsFor(String identityKey) async {
    final meta = _cache[identityKey];
    if (meta == null) return null;
    if (meta.details != null) return meta.details;
    try {
      final details = meta.movie.provider == MetadataProvider.theTvdb
          ? await _theTvdb.details(meta.movie)
          : await _api.details(meta.movie);
      if (details == null) return null;
      // Merge onto the FRESHEST cache entry, not the snapshot taken before the
      // network call — a concurrent seasonFor/withDetails write may have added
      // seasons to the same key while this request was in flight. Writing back
      // the stale snapshot would silently drop those seasons (regression: a
      // folder card that briefly showed its season poster reverted to the
      // show's main poster).
      final fresh = _cache[identityKey] ?? meta;
      _cache[identityKey] = fresh.withDetails(details);
      await TmdStore.save(identityKey, _cache[identityKey]!);
      // Prefetch backdrop, cast profiles, and stills for offline use.
      ImageCacheService.instance.prefetchImages(
        backdropUrl: metadataImageUrl(details.backdropPath, width: 780),
        stillUrls: details.stillUrls(),
        profileUrls: details.cast
            .map((c) => c.profileUrl())
            .whereType<String>()
            .toList(),
      );
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
    debugPrint(
      'TMDB seasonFor($identityKey,$seasonNumber) cached=${cached != null} hasSeason=${cached?.seasons[seasonNumber]?.posterPath != null}',
    );
    if (cached == null || cached.movie.kind != TmdKind.tv) return null;
    final already = cached.seasons[seasonNumber];
    // A season may exist with only a poster/name (from the show-details
    // endpoint) but no episodes.  Only short-circuit when episodes are
    // actually present — otherwise we must fetch the per-season endpoint.
    if (already != null && already.episodes.isNotEmpty) return already;
    final pendingKey = '$identityKey#s$seasonNumber';
    if (_pendingDetail.contains(pendingKey)) return null;

    _pendingDetail.add(pendingKey);
    try {
      if (cached.movie.provider == MetadataProvider.theTvdb) {
        final episodes = await _theTvdb.seasonEpisodes(
          cached.movie,
          season: seasonNumber,
        );
        if (episodes.isEmpty) return null;
        final available = await _theTvdb.seasons(cached.movie);
        final remoteSeason = available
            .where((item) => item.seasonNumber == seasonNumber)
            .firstOrNull;
        final season = TmdSeason(
          seasonNumber: seasonNumber,
          name: remoteSeason?.name ?? 'Season $seasonNumber',
          overview: remoteSeason?.overview ?? '',
          posterPath: remoteSeason?.posterPath ?? cached.movie.posterPath,
          episodes: episodes,
        );
        _cache[identityKey] = (_cache[identityKey] ?? cached).withSeason(
          season,
        );
        await TmdStore.save(identityKey, _cache[identityKey]!);
        ImageCacheService.instance.prefetchImages(
          posterUrl: season.posterUrl(),
          stillUrls: episodes
              .map((e) => e.stillUrl())
              .whereType<String>()
              .toList(),
        );
        return season;
      }
      // Fetch the full season endpoint — it includes poster_path, name,
      // overview AND the episodes list.
      final key = await _api.effectiveApiKey();
      if (key.isEmpty) return null;
      final json = await _api._get(
        '/tv/${cached.movie.id}/season/$seasonNumber?api_key=$key&language=en-US',
      );
      final episodes = (json['episodes'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TmdEpisode.fromJson)
          .where((e) => e.episodeNumber > 0)
          .toList();
      if (episodes.isEmpty) return null;
      final season = TmdSeason(
        seasonNumber: seasonNumber,
        name: json['name'] as String? ?? '',
        overview: json['overview'] as String? ?? '',
        posterPath: json['poster_path'] as String?,
        episodes: episodes,
      );
      _cache[identityKey] = (_cache[identityKey] ?? cached).withSeason(season);
      debugPrint(
        'TMDB seasonFor STORED $identityKey season=$seasonNumber poster=${season.posterPath} episodes=${episodes.length}',
      );
      await TmdStore.save(identityKey, _cache[identityKey]!);
      // Prefetch season poster + episode stills for offline use.
      ImageCacheService.instance.prefetchImages(
        posterUrl: season.posterUrl(),
        stillUrls: episodes
            .map((e) => e.stillUrl())
            .whereType<String>()
            .toList(),
      );
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
    if (cached.movie.provider == MetadataProvider.theTvdb) return existing;
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
      final fresh = _cache[identityKey] ?? cached;
      final freshSeason = fresh.seasons[seasonNumber] ?? season;
      _cache[identityKey] = fresh.withSeason(freshSeason.withEpisode(enriched));
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
  ///
  /// [folderSeason] is the season the user (or Fix match dialog) picked.
  /// When it is null and [folderName] is a TV folder name, the season is
  /// resolved against the show's TMDB season names (issue #22 — a bare
  /// [TmdMeta] with no [TmdMeta.folderSeason] left Railgun S/T folders
  /// looking like Season 1 of the main show).
  Future<void> setManual(
    VideoItem video, TmdMovie movie, {
    int? folderSeason, String? folderName,
  }) async {
    final identityKey = TmdStore.identityKeyFor(video);
    if (identityKey.isEmpty) return;
    await ensureLoaded();
    final season = await _resolveManualSeason(movie, folderSeason, folderName);
    final existing = _cache[identityKey];
    _cache[identityKey] = TmdMeta(
      movie: movie,
      details: existing?.movie.providerKey == movie.providerKey
          ? existing?.details : null,
      seasons: existing?.movie.providerKey == movie.providerKey
          ? existing!.seasons : const {},
      folderSeason: season,
      manual: true,
    );
    await TmdStore.save(identityKey, _cache[identityKey]!);
    // Lift any "Remove info" suppression so the manual entry is returned
    // by resolve()/resolveFolder() on subsequent calls.
    _suppressed.remove(identityKey);
    await TmdStore.unsuppress(identityKey);
    notifyListeners();
  }

  /// Manual fix for a library folder (identity = `folder:<id>`), so the folder
  /// details screen can be pinned to a TV series without a video.
  /// Same [folderSeason]/[folderName] resolution as [setManual].
  Future<void> setManualFolder(
    String metadataKey, TmdMovie movie, {
    int? folderSeason, String? folderName,
  }) async {
    await ensureLoaded();
    final season = await _resolveManualSeason(movie, folderSeason, folderName);
    final existing = _cache[metadataKey];
    _cache[metadataKey] = TmdMeta(
      movie: movie,
      details: existing?.movie.providerKey == movie.providerKey
          ? existing?.details : null,
      seasons: existing?.movie.providerKey == movie.providerKey
          ? existing!.seasons : const {},
      folderSeason: season,
      manual: true,
    );
    await TmdStore.save(metadataKey, _cache[metadataKey]!);
    _suppressed.remove(metadataKey);
    await TmdStore.unsuppress(metadataKey);
    notifyListeners();
  }

  /// Resolves the season for a manual pin: explicit [folderSeason] wins;
  /// otherwise match [folderName] against the show's TMDB season names
  /// (fetched once and cached). Returns null for movies / no folder name.
  Future<int?> _resolveManualSeason(
      TmdMovie movie, int? folderSeason, String? folderName,
  ) async {
    if (folderSeason != null) return folderSeason;
    if (movie.kind != TmdKind.tv) return null;
    final name = folderName?.trim();
    if (name == null || name.isEmpty) return null;
    final seasonKey = _seasonKeyForMovie(movie);
    var names = _seasonNamesCache[seasonKey];
    if (names == null || names.isEmpty) {
      try {
        names = movie.provider == MetadataProvider.theTvdb
            ? await _theTvdb.seasonNames(movie)
            : await _api.seasonNames(movie);
      if (names.isNotEmpty) {
          _seasonNamesCache[seasonKey] = names;
        await _savePersistedSeasonNames();
      }
      } catch (_) {
        return null;
      }
    }
    if (names.isEmpty) return null;
    return matchFolderToSeasonName(name, names);
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

  /// "Remove info" (user intent): clears the entry AND records it in the
  /// suppression list so no auto-resolution re-fetches the same match on the
  /// next home refresh/rescan/folder open. An explicit Fix match
  /// ([setManual]/[setManualFolder]) lifts the suppression.
  Future<void> removeInfo(String identityKey) async {
    if (identityKey.isEmpty) return;
    _cache.remove(identityKey);
    await TmdStore.remove(identityKey);
    _suppressed.add(identityKey);
    await TmdStore.suppress(identityKey);
    notifyListeners();
  }

  /// Nova-style: carry a folder's TMDB metadata to every video file inside it.
  /// For a TV show folder this means every episode gets the show's poster
  /// without re-searching TMDB per file.
  void carryFolderMetaToAll(String folderKey,
    List<VideoItem> videos) {
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
