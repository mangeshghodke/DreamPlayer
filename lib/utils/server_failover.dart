// Pure helpers for the "dual server address" feature: every network source
// (SMB, WebDAV, Jellyfin) can carry an optional alternate address (e.g. the
// LAN IP at home vs. the public IP on the road). The alternate is stored
// Dart-side (`ServerAltStore`) because the native server stores do not
// round-trip extra fields; failover works by re-pointing the *saved* server
// at the alternate address (native `saveServer` keeps the stored password
// when the password argument is empty on both platforms), so every
// id-keyed native call — listShares / listDirectory / openShare / auth
// header / playback — transparently follows without any native change.

/// Parses an SMB alternate address into host + port.
/// Accepts `host`, `host:port`, `http(s)://host[:port]` (scheme is stripped).
/// Returns null for empty/garbage input.
({String host, int port})? parseSmbAltAddress(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  s = s.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
  s = s.split('/').first; // drop any path
  final port = s.contains(':')
      ? int.tryParse(s.split(':').last)
      : null;
  final host = port == null ? s : s.substring(0, s.lastIndexOf(':'));
  if (host.isEmpty) return null;
  return (host: host, port: port ?? 445);
}

/// Normalizes an alternate base URL (trims whitespace, strips trailing
/// slashes). Returns null when empty.
String? normalizeAltUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'http://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Runs [primary]. If it throws and [alt] is a non-empty address, [persistAlt]
/// is called with the alt (re-pointing the saved server), then [runAlt] runs.
/// If [runAlt] also throws, [persistAlt] is called with null to restore the
/// primary and the ORIGINAL error is rethrown. With no alt, the primary error
/// propagates untouched and nothing is persisted.
Future<T> runWithAltFailover<T>({
  required Future<T> Function() primary,
  required String? alt,
  required Future<T> Function(String alt) runAlt,
  required Future<void> Function(String? alt) persistAlt,
}) async {
  try {
    return await primary();
  } catch (e) {
    final a = alt?.trim();
    if (a == null || a.isEmpty) rethrow;
    await persistAlt(a);
    try {
      return await runAlt(a);
    } catch (_) {
      await persistAlt(null);
      throw e; // the ORIGINAL primary error, not the alt's
    }
  }
}
