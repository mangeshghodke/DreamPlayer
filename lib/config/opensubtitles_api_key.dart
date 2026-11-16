/// Default OpenSubtitles API key (REST api.opensubtitles.com).
///
/// Resolution: the `--dart-define=OPENSUBTITLES_API_KEY=...` value, else ''.
/// Get your own free key at https://www.opensubtitles.com/en/api - create an
/// API Consumer in your profile. Anonymous downloads = 5/day/IP, free login =
/// 20/day (VIP more) - all with the same developer key.
const String opensubtitlesDefaultApiKey =
    String.fromEnvironment('OPENSUBTITLES_API_KEY');
