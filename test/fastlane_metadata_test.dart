import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the Fastlane listing metadata against the limits every storefront that
/// reads it enforces.
///
/// Each of these fails *silently* on the store side (a description is
/// truncated, a changelog is dropped, an icon is ignored), and two of them are
/// easy to get wrong by hand:
///
///  * `changelogs/<name>.txt` must be the **Android `versionCode`** - the
///    hand-pinned value in `build.gradle.kts`, not pubspec's `+N` build number.
///    Renaming it to `54.txt` after a pubspec bump drops the changelog for the
///    release it was written for.
///  * the changelog is capped at **500 bytes** and must be plain ASCII.
///
/// Image constraints (icon ≤512 px, featureGraphic 1024x500 or 512x250,
/// screenshot ratio ≤2:1) are not checked here - run
/// `docker run --rm -v "$PWD:/github/workspace" -w /github/workspace \
///   ashutoshgngwr/validate-fastlane-supply-metadata:v2`
/// which is the validator F-Droid/IzzyOnDroid recommend.
void main() {
  const root = 'fastlane/metadata/android/en-US';

  int androidVersionCode() {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final match =
        RegExp(r'^\s*versionCode\s*=\s*(\d+)', multiLine: true).firstMatch(gradle);
    expect(match, isNotNull, reason: 'no pinned versionCode in build.gradle.kts');
    return int.parse(match!.group(1)!);
  }

  test('required text files exist and respect their limits', () {
    final title = File('$root/title.txt').readAsStringSync().trim();
    final short = File('$root/short_description.txt').readAsStringSync().trim();
    final full = File('$root/full_description.txt').readAsStringSync();

    expect(title, isNotEmpty);
    expect(title.length, lessThanOrEqualTo(30));
    expect(short.length, lessThanOrEqualTo(80));
    expect(full.length, lessThanOrEqualTo(4000));
    expect(full, isNotEmpty);
  });

  test('the changelog is named after the pinned Android versionCode', () {
    final changelog = File('$root/changelogs/${androidVersionCode()}.txt');
    expect(
      changelog.existsSync(),
      isTrue,
      reason: 'expected ${changelog.path} (hand-pinned versionCode, '
          'NOT pubspec build number)',
    );

    final bytes = changelog.readAsBytesSync();
    expect(bytes.length, lessThanOrEqualTo(500));
    expect(
      bytes.every((b) => b < 128),
      isTrue,
      reason: 'changelogs must be plain ASCII',
    );
    expect(utf8.decode(bytes).trim(), isNotEmpty);
  });

  test('listing images are present', () {
    for (final path in [
      '$root/images/icon.png',
      '$root/images/featureGraphic.png',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
    final shots = Directory('$root/images/phoneScreenshots')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png') || f.path.endsWith('.jpg'))
        .toList();
    expect(shots, isNotEmpty, reason: 'phoneScreenshots are recommended');
  });
}
