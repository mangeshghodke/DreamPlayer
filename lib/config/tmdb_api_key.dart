/// Default TMDB API key (v3 auth).
///
/// Resolution order in [TmdApi.effectiveApiKey]:
///   1. the key entered in Settings (stored in shared_preferences under
///      `dreamplayer.tmdbApiKey`)
///   2. this default: the `--dart-define=TMDB_API_KEY=...` value, else ''.
///
/// Get your own free key at https://www.themoviedb.org/settings/api - enter it
/// in the app's Settings -> Metadata screen (it is never written to the repo).
const String tmdbDefaultApiKey = String.fromEnvironment('TMDB_API_KEY');
