import '../services/tmdb_client.dart';

/// `S01E05` - the season/episode code for a row's badge and offline title.
String episodeCode(int season, int episode) =>
    'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';

/// Title line for an episode / video row.
///
/// Falls back progressively, because the TMDB name is only ever available when
/// metadata resolved — and offline there is none:
///
/// 1. The TMDB episode name ("Tarnished Cities").
/// 2. `S01E05` — **not** `ParsedFileName.title`, which for a file like
///    `Dark.S01E05.mkv` is the *show* name, so every row in a season rendered
///    the same "Dark" and the list was unreadable without a connection.
/// 3. The file name, for a movie or anything unparseable.
String episodeRowTitle({
  required ParsedFileName parsed,
  required String fileName,
  String? tmdbName,
}) {
  final name = tmdbName?.trim() ?? '';
  if (name.isNotEmpty) return name;
  if (parsed.isEpisode && parsed.season > 0 && parsed.episode > 0) {
    return episodeCode(parsed.season, parsed.episode);
  }
  final base = fileName.trim();
  return base.isEmpty ? 'Video' : base;
}

/// Whether the title line already shows the episode code.
///
/// When it does (offline, or an episode TMDB never named) the row's second line
/// must not repeat it, or every row reads "S01E05 / S01E05".
bool titleIsEpisodeCode({
  required ParsedFileName parsed,
  required String title,
}) =>
    parsed.isEpisode &&
    parsed.season > 0 &&
    parsed.episode > 0 &&
    title == episodeCode(parsed.season, parsed.episode);
