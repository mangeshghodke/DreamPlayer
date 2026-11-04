import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the Obtainium "add app" deep link.
///
/// The link is `https://apps.obtainium.imranr.dev/redirect?r=<encoded>` where
/// `<encoded>` is itself `obtainium://app/<encoded JSON>` — two layers of
/// percent-encoding. Getting either layer wrong is silent: the redirect page
/// loads, the app link does nothing, and the only symptom is a reader deciding
/// the badge is broken. So the payload is decoded back here and checked.
void main() {
  const repo = 'https://github.com/mangeshghodke/DreamPlayer';
  const redirectHost = 'https://apps.obtainium.imranr.dev/redirect?r=';

  /// Returns the decoded `obtainium://` payload for every link in [file].
  List<String> payloadsIn(String path) {
    final content = File(path).readAsStringSync();
    return RegExp('${RegExp.escape(redirectHost)}([^"\\s<>]+)')
        .allMatches(content)
        .map((m) => Uri.decodeComponent(m.group(1)!))
        .toList();
  }

  test('README and website both carry a working Obtainium link', () {
    for (final path in ['README.md', 'docs/index.html']) {
      final payloads = payloadsIn(path);
      expect(payloads, isNotEmpty, reason: '$path has no Obtainium link');

      for (final payload in payloads) {
        expect(payload, startsWith('obtainium://app/'));

        // Two encoding layers: the `r` parameter encodes the whole app link,
        // and the JSON inside that link is itself encoded for the URI path.
        final json = jsonDecode(
          Uri.decodeComponent(payload.substring('obtainium://app/'.length)),
        );
        expect(json, isA<Map<String, dynamic>>());
        final config = json as Map<String, dynamic>;
        expect(config['id'], 'com.dreamplayer.app');
        expect(config['url'], repo);
        expect(config['name'], 'DreamPlayer');
        expect(config['author'], 'mangeshghodke');
      }
    }
  });

  test('the badge image the README references is committed', () {
    final readme = File('README.md').readAsStringSync();
    expect(
      readme,
      contains(
        'https://dreamplayer.isroot.in/assets/img/badge-obtainium.png',
      ),
    );
    expect(File('docs/assets/img/badge-obtainium.png').existsSync(), isTrue);
  });
}
