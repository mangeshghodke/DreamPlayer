import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/accent_store.dart';

/// The iOS unlock splash (SceneDelegate.showUnlockSplash).
///
/// Two things are pinned here, both of them shipped bugs:
///
///  1. **The splash must use the app's theme colour, not black.** It is the
///     accent the user picked in Settings → Appearance, so the unlock screen
///     matches the app they are unlocking into.
///
///  2. **The icon must actually load.** `UIImage(named:)` cannot load an app
///     icon: the asset compiler treats `.appiconset` assets specially and
///     they are not in the regular image namespace, so the old lookup of
///     `UIImage(named: "AppIcon")` returned nil and the splash showed as a
///     blank rectangle with no icon at all. The icon now comes from a
///     dedicated `SplashIcon*.imageset`.
void main() {
  final sceneDelegate =
      File('ios/Runner/SceneDelegate.swift').readAsStringSync();
  final accentStore =
      File('lib/services/accent_store.dart').readAsStringSync();

  group('unlock splash colour', () {
    test('does not use a black background', () {
      expect(sceneDelegate, isNot(contains('backgroundColor = .black')));
      expect(sceneDelegate, isNot(contains('UIColor.black')));
    });

    test('uses the NavigationBar indicator colour, persisted by Dart', () {
      // The splash must be the same pill colour the home NavigationBar shows
      // behind the selected Library/Settings destination. Dart computes it
      // (ColorScheme.primaryContainer of the current accent) and persists it
      // as 0xAARRGGBB; the native side reads it — M3 tone mapping is not
      // re-implemented in Swift.
      expect(sceneDelegate, contains('flutter.dreamplayer.accentIndicator'));
      expect(sceneDelegate, contains('func color(fromHex'));
      expect(accentStore, contains("'dreamplayer.accentIndicator'"));
      expect(accentStore, contains('indicatorColorFor'));
      expect(accentStore, contains('primaryContainer'));
      // Fallback when the pref is missing: the raw accent mirror.
      expect(sceneDelegate, contains('flutter.dreamplayer.accent'));
    });

    test('every Dart accent has a matching Swift fallback colour', () {
      // The palette is defined once in Dart (AccentStore.accents) and
      // mirrored in Swift (SceneDelegate.accentColor(for:)). A drift means
      // the splash shows a colour the app never uses.
      final dartColors = RegExp(r"Accent\('([a-z]+)', '[^']*', Color\(0xFF([0-9A-Fa-f]{6})\)\)")
          .allMatches(accentStore)
          .map((m) => '${m.group(1)}:#${m.group(2)!.toUpperCase()}')
          .toList();
      expect(dartColors, isNotEmpty);
      expect(dartColors.length, AccentStore.accents.length);

      for (final entry in dartColors) {
        final id = entry.split(':').first;
        final hex = entry.split(':').last;
        // Swift stores the channels as 0xRR/255.0, 0xGG/255.0, 0xBB/255.0.
        // (255.0, not 255 — integer division in Swift would make every
        // accent black.)
        final r = int.parse(hex.substring(1, 3), radix: 16);
        final g = int.parse(hex.substring(3, 5), radix: 16);
        final b = int.parse(hex.substring(5, 7), radix: 16);
        final swift = '0x${r.toRadixString(16).toUpperCase().padLeft(2, '0')} / 255.0, '
            'green: 0x${g.toRadixString(16).toUpperCase().padLeft(2, '0')} / 255.0, '
            'blue: 0x${b.toRadixString(16).toUpperCase().padLeft(2, '0')} / 255.0';
        expect(
          sceneDelegate,
          contains(swift),
          reason: 'accent "$id" ($hex) is missing from the Swift palette',
        );
        // Guard against the integer-division trap that would render every
        // accent as black.
        expect(sceneDelegate, isNot(contains('/ 255,')),
            reason: 'Swift integer division (/ 255) would make the accent '
                'black — use / 255.0');
      }
    });
  });

  group('unlock splash icon', () {
    test('loads the icon from a regular imageset, not the appiconset', () {
      expect(sceneDelegate, contains('UIImage(named: imageSet)'));
      expect(sceneDelegate, isNot(contains('UIImage(named: iconName)')));
      // The failure is logged loudly instead of silently showing a bare
      // coloured screen.
      expect(sceneDelegate, contains('ICON MISSING'));
    });

    test('every launcher icon variant has a matching splash imageset', () {
      const variants = {
        'AppIcon': 'SplashIcon',
        'AppIconMark': 'SplashIconMark',
        'AppIconRed': 'SplashIconRed',
        'AppIconGreen': 'SplashIconGreen',
        'AppIconCyan': 'SplashIconCyan',
      };
      for (final entry in variants.entries) {
        expect(
          sceneDelegate,
          contains('case "${entry.key}": return "${entry.value}"'),
          reason: '${entry.key} is not mapped to ${entry.value}',
        );
        final set = Directory(
            'ios/Runner/Assets.xcassets/${entry.value}.imageset');
        expect(set.existsSync(), isTrue,
            reason: '${entry.value}.imageset is missing');
        expect(File('${set.path}/${entry.value}.png').existsSync(), isTrue,
            reason: '${entry.value}.png is missing');
        expect(File('${set.path}/Contents.json').existsSync(), isTrue);
      }
    });

    test('the splash imagesets are real artwork, not placeholders', () {
      for (final dir in Directory('ios/Runner/Assets.xcassets')
          .listSync()
          .whereType<Directory>()
          .where((d) =>
              d.path.endsWith('.imageset') &&
              d.path.split('/').last.startsWith('SplashIcon'))) {
        final name = dir.path.split('/').last.replaceAll('.imageset', '');
        final png = File('${dir.path}/$name.png');
        expect(png.existsSync(), isTrue, reason: '${dir.path} has no PNG');
        expect(png.lengthSync(), greaterThan(1000),
            reason: '${png.path} looks like an empty placeholder');
      }
    });
  });
}
