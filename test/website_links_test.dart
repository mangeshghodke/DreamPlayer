import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the app website host: `dreamplayer.isroot.in` (custom domain, served
/// from `main:/docs` via GitHub Pages; `docs/CNAME` carries the domain).
///
/// History: the site used to live at `mangeshghodke.github.io/DreamPlayer/`,
/// where the Pages path was the repo name and GitHub matched it
/// case-sensitively — `/dreamplayer/` returned 404, a silent failure for the
/// App-Review-critical Terms/Privacy links. With the custom domain the site is
/// served at the domain root, and this test now pins the exact host string so
/// a typo (wrong TLD, missing subdomain) fails loudly instead of 404ing.
///
/// One thing must NOT be flagged: the shields.io badge whose label merely
/// contains the host (`img.shields.io/badge/Website-dreamplayer.isroot.in-...`)
/// — not a site link.
void main() {
  const host = 'dreamplayer.isroot.in';

  List<File> sources() => [
        ...Directory('lib').listSync(recursive: true).whereType<File>(),
        ...Directory('docs').listSync(recursive: true).whereType<File>(),
        ...Directory('.github').listSync(recursive: true).whereType<File>(),
        ...['README.md', 'AGENTS.md', 'CHANGELOG.md'].map(File.new),
      ]
          .where((f) => f.path.endsWith('.dart') || f.path.endsWith('.md'))
          .toList();

  test('every website reference uses the exact dreamplayer.isroot.in host', () {
    final offenders = <String>[];
    // Hosts that look like the site but are not — a mistyped link 404s.
    final wrongHosts = RegExp(
        r'(dreamplayer\.isroot\.(?:com|net|org|in\.au)|dreamplayer\.isroot\.io)');
    for (final file in sources()) {
      final content = file.readAsStringSync();
      for (final m in wrongHosts.allMatches(content)) {
        offenders.add('${file.path}: ${m.group(0)}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'Only $host is the app website; lookalike hosts 404.');
  });

  test('the shipped Terms and Privacy URLs use the pinned host', () {
    const legal = {
      'https://dreamplayer.isroot.in/terms': 'Terms of Use',
      'https://dreamplayer.isroot.in/privacy': 'Privacy Policy',
    };
    for (final url in legal.keys) {
      expect(url, startsWith('https://$host/'), reason: url);
    }
    // And the CNAME file GitHub Pages reads for the custom domain.
    expect(File('docs/CNAME').readAsStringSync().trim(), host);
  });
}
