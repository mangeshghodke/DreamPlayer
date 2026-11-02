import 'dart:convert';
import 'dart:io';

import '../config/introdb_base_url.dart';

/// Optional remote intro/credits lookup (IntroDB-compatible). Compiled in
/// only when `--dart-define=INTRODB_BASE_URL=...` is set; [available] is
/// false otherwise and callers must not call [lookup].
///
/// Expected response shape for `GET {base}/lookup?title=..&durationMs=..`:
/// `{ "introStartMs": 0, "introEndMs": 95000, "creditsStartMs": 1300000 }`
/// — any field may be null/absent when unknown.
class IntroDb {
  IntroDb._();

  static bool get available => introdbDefaultBaseUrl.isNotEmpty;

  static Future<({int? introEndMs, int? creditsStartMs})?> lookup({
    required String title,
    int? durationMs,
  }) async {
    if (!available) return null;
    final base = introdbDefaultBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/lookup').replace(queryParameters: {
      'title': title,
      if (durationMs != null) 'durationMs': durationMs.toString(),
    });
    try {
      final client = HttpClient();
      try {
        final req = await client.getUrl(uri).timeout(const Duration(seconds: 5));
        final res = await req.close().timeout(const Duration(seconds: 5));
        if (res.statusCode != 200) return null;
        final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
        final json = jsonDecode(body);
        if (json is! Map) return null;
        int? read(String key) =>
            json[key] is num ? (json[key] as num).toInt() : null;
        return (
          introEndMs: read('introEndMs'),
          creditsStartMs: read('creditsStartMs'),
        );
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return null; // offline / bad endpoint must never break playback UI
    }
  }
}
