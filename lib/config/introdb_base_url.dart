/// Optional IntroDB-compatible lookup base URL.
///
/// Resolution: the `--dart-define=INTRODB_BASE_URL=...` value, else ''.
/// Empty means the remote lookup is compiled out and only chapter-name
/// matching (lib/utils/skip_chapters.dart) is used — the Settings toggle is
/// hidden in that case, exactly like an unconfigured metadata adapter.
const String introdbDefaultBaseUrl = String.fromEnvironment('INTRODB_BASE_URL');
