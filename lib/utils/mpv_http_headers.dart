/// Pure helpers for handing a remote source's HTTP headers to the **libmpv**
/// engine.
///
/// ## Why this exists
///
/// The two engines use different HTTP stacks:
///
///  * Media3 → OkHttp (Conscrypt TLS, `User-Agent: okhttp/4.x`).
///  * libmpv → ffmpeg's own http protocol (bundled mbedtls,
///    `User-Agent: Lavf/63.1.100`).
///
/// Two things were broken on the mpv path:
///
///  1. **`VideoItem.httpHeaders` was dropped entirely** — so every
///     authenticated URL (WebDAV Basic auth, a Jellyfin token) could never
///     play on this engine.
///  2. ffmpeg's default `User-Agent: Lavf/…` identifies itself as a media
///     ripper and is refused by a lot of CDNs — which is why a link Media3
///     opened was rejected by mpv.
///
/// This file owns the mapping; `player_screen.dart` only applies it.
library;

/// A browser-ish `User-Agent` used for the mpv engine's http requests.
///
/// ffmpeg's own default (`Lavf/63.1.100`) is on plenty of CDN blocklists.
const String mpvBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// The mpv properties that carry a remote source's HTTP headers.
class MpvHttpHeaderOptions {
  const MpvHttpHeaderOptions({
    required this.userAgent,
    this.referrer,
    this.headerFields,
  });

  /// mpv's `user-agent` property. Never empty — the browser UA is the
  /// fallback when the source does not supply one.
  final String userAgent;

  /// mpv's `referrer` property, when the source supplies one.
  final String? referrer;

  /// mpv's `http-header-fields` property: a comma-separated list of
  /// `Name: value` pairs. Null when the source supplies no extra headers.
  final String? headerFields;

  /// True when there is nothing extra to send beyond the user agent.
  bool get isEmpty => headerFields == null && referrer == null;
}

/// Maps [headers] onto the mpv properties that reproduce them.
///
/// Rules:
///  * `User-Agent` → mpv's dedicated `user-agent` property.
///  * `Referer` / `Referrer` → mpv's dedicated `referrer` property.
///  * Everything else → the `http-header-fields` list.
///
/// mpv splits `http-header-fields` on **commas**, so a comma inside a value
/// has to be escaped as `\,` (and a backslash as `\\`) — otherwise
/// `Authorization: Basic dXNlcjpwYXNz` style values, or a cookie list, get
/// split into bogus headers.
MpvHttpHeaderOptions buildMpvHttpHeaderOptions(
  Map<String, String> headers, {
  String defaultUserAgent = mpvBrowserUserAgent,
}) {
  String? userAgent;
  String? referrer;
  final rest = <String>[];

  for (final entry in headers.entries) {
    final name = entry.key.trim();
    final value = entry.value.trim();
    if (name.isEmpty || value.isEmpty) continue;
    final lower = name.toLowerCase();
    if (lower == 'user-agent') {
      userAgent = value;
    } else if (lower == 'referer' || lower == 'referrer') {
      referrer = value;
    } else {
      rest.add('$name: ${_escapeMpvHeaderValue(value)}');
    }
  }

  return MpvHttpHeaderOptions(
    userAgent: (userAgent == null || userAgent.isEmpty)
        ? defaultUserAgent
        : userAgent,
    referrer: referrer,
    headerFields: rest.isEmpty ? null : rest.join(','),
  );
}

/// Escapes a header value for mpv's comma-separated `http-header-fields`.
String _escapeMpvHeaderValue(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll(',', '\\,');
