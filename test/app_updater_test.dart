import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/app_updater.dart';

void main() {
  group('compareVersions', () {
    test('newer patch wins', () {
      expect(AppUpdater.compareVersions('0.5.3', '0.5.2'), greaterThan(0));
    });

    test('compares numerically, not as strings', () {
      expect(AppUpdater.compareVersions('0.5.10', '0.5.9'), greaterThan(0));
      expect(AppUpdater.compareVersions('0.10.0', '0.9.9'), greaterThan(0));
      expect(AppUpdater.compareVersions('1.0.0', '0.99.99'), greaterThan(0));
    });

    test('equal versions compare equal', () {
      expect(AppUpdater.compareVersions('0.5.2', '0.5.2'), 0);
    });

    test('older versions compare less', () {
      expect(AppUpdater.compareVersions('0.5.1', '0.5.2'), lessThan(0));
    });

    test('build metadata and prerelease suffixes are ignored', () {
      expect(AppUpdater.compareVersions('0.5.3+12', '0.5.3'), 0);
      expect(AppUpdater.compareVersions('0.5.3-beta.1', '0.5.2'), greaterThan(0));
    });

    test('a missing segment counts as zero', () {
      expect(AppUpdater.compareVersions('0.5', '0.5.0'), 0);
      expect(AppUpdater.compareVersions('0.6', '0.5.9'), greaterThan(0));
    });
  });

  group('cleanReleaseNotes', () {
    test('drops heading hashes and keeps the heading text', () {
      expect(
        AppUpdater.cleanReleaseNotes('### Added\n- Faster start-up'),
        'Added\n\u2022 Faster start-up',
      );
    });

    test('turns dashes and asterisks into bullets', () {
      expect(
        AppUpdater.cleanReleaseNotes('- one\n* two'),
        '\u2022 one\n\u2022 two',
      );
    });

    test('unwraps markdown links to their text', () {
      expect(
        AppUpdater.cleanReleaseNotes(
          'See [the notes](https://example.com/a_(b)) for details',
        ),
        'See the notes for details',
      );
    });

    test('keeps paragraph breaks and trims the ends', () {
      expect(AppUpdater.cleanReleaseNotes('\n\nFixed.\n\nNew.\n\n'), 'Fixed.\n\nNew.');
    });

    test('strips bold and inline code markers', () {
      expect(
        AppUpdater.cleanReleaseNotes('**New** `search` screen'),
        'New search screen',
      );
    });

    test('caps very long notes', () {
      final cleaned = AppUpdater.cleanReleaseNotes('x' * 5000);
      expect(cleaned.length, 2001);
      expect(cleaned.endsWith('\u2026'), isTrue);
    });

    test('empty body stays empty', () {
      expect(AppUpdater.cleanReleaseNotes(''), '');
    });
  });

  group('releaseNotesSection', () {
    test('keeps the version entry and drops the install guide', () {
      const body = '## 0.5.4\n\n### Added\n- Search\n\n'
          '## Download & install\n\nLong guide.';
      expect(
        AppUpdater.releaseNotesSection(body),
        '## 0.5.4\n\n### Added\n- Search\n',
      );
    });

    test('a body without headings is returned whole', () {
      expect(AppUpdater.releaseNotesSection('Just notes.'), 'Just notes.');
    });
  });

  group('AvailableUpdate', () {
    AvailableUpdate update({String installed = '0.5.2'}) => AvailableUpdate(
          version: '0.5.3',
          installedVersion: installed,
          notes: 'notes',
          assetUrl:
              'https://github.com/mangeshghodke/DreamPlayer/releases/download/v0.5.3/DreamPlayer-0.5.3-arm64-v8a.apk',
          releaseTag: 'v0.5.3',
        );

    test('file name comes from the asset URL', () {
      expect(update().fileName, 'DreamPlayer-0.5.3-arm64-v8a.apk');
    });

    test('warns about the one-time uninstall before 0.5.2', () {
      expect(update(installed: '0.5.1').needsOneTimeUninstall, isTrue);
      expect(update(installed: '0.4.9').needsOneTimeUninstall, isTrue);
    });

    test('does not warn from 0.5.2 onward, where the key is stable', () {
      expect(update(installed: '0.5.2').needsOneTimeUninstall, isFalse);
      expect(update(installed: '0.5.9').needsOneTimeUninstall, isFalse);
    });
  });
}
