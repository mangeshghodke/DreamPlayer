import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/app_icon_service.dart';

/// The default launcher icon is the LOGO ONLY (mark) since 0.5.7; the original
/// logo + "DreamPlayer" wordmark stays as a secondary option. This is pinned on
/// every layer that decides it, because a drift on any one side silently
/// reverts the default:
///
///  * iOS asset catalog: primary appicon = AppIconMark, "AppIcon" is an
///    alternate (project.pbxproj, all 3 build configs)
///  * iOS runtime: nil alternateIconName -> "mark" (IconSwitcher.swift)
///  * Android manifest: MainActivityAltMark enabled by default, AltDefault off
///  * Android runtime: FALLBACK = "mark" + a one-time migration off the old
///    wordmark default (IconSwitcher.kt)
///  * Dart: the service's initial style is markOnly
void main() {
  final pbxproj =
      File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
  final iconSwitcherSwift =
      File('ios/Runner/IconSwitcher.swift').readAsStringSync();
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final iconSwitcherKt = File(
          'android/app/src/main/kotlin/com/dreamplayer/app/IconSwitcher.kt')
      .readAsStringSync();

  group('iOS asset catalog', () {
    test('primary app icon is the mark in all three build configs', () {
      expect(
        pbxproj,
        contains('ASSETCATALOG_COMPILER_APPICON_NAME = AppIconMark;'),
      );
      expect(
        pbxproj.split('ASSETCATALOG_COMPILER_APPICON_NAME = AppIconMark;').length - 1,
        3,
        reason: 'expected the setting in all 3 build configurations',
      );
      expect(pbxproj, isNot(contains('ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')));
    });

    test('the wordmark AppIcon is an alternate, not the primary', () {
      expect(
        pbxproj,
        contains(
            'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "AppIcon AppIconRed AppIconGreen AppIconCyan";'),
      );
    });
  });

  group('iOS runtime mapping', () {
    test('nil alternateIconName (primary) reports the mark', () {
      // The switch's default arm must be "mark" now that the primary icon
      // is the mark.
      expect(iconSwitcherSwift, contains('default: result("mark")'));
    });

    test('wordmark maps to the AppIcon alternate, mark restores the primary', () {
      expect(iconSwitcherSwift, contains('case wordmark = "AppIcon"'));
      expect(iconSwitcherSwift, contains('case "default": target = AppIconVariant.wordmark.rawValue'));
      expect(iconSwitcherSwift, contains('case "mark": target = nil'));
    });
  });

  group('Android manifest', () {
    test('the mark alias is the one enabled by default', () {
      final mark = RegExp(
              r'MainActivityAltMark".*?android:enabled="(true|false)"',
              dotAll: true)
          .firstMatch(manifest);
      final wordmark = RegExp(
              r'MainActivityAltDefault".*?android:enabled="(true|false)"',
              dotAll: true)
          .firstMatch(manifest);
      expect(mark, isNotNull);
      expect(wordmark, isNotNull);
      expect(mark!.group(1), 'true', reason: 'AltMark must be the default-enabled alias');
      expect(wordmark!.group(1), 'false', reason: 'AltDefault (wordmark) is now an alternate');
    });
  });

  group('Android runtime', () {
    test('the fallback variant is the mark', () {
      expect(iconSwitcherKt, contains('const val FALLBACK = "mark"'));
      expect(iconSwitcherKt, contains('enable(component(FALLBACK))'));
    });

    test('existing installs migrate off the old wordmark default once', () {
      expect(iconSwitcherKt, contains('migrateDefaultIconOnce'));
      expect(iconSwitcherKt, contains('if (current == DEFAULT)'));
      expect(iconSwitcherKt, contains('applyVariant(FALLBACK)'));
    });
  });

  group('Dart service', () {
    test('the initial style is the logo-only mark', () {
      expect(AppIconStyle.markOnly.nativeName, 'mark');
      expect(AppIconStyle.markOnly.iosAlternateIconName, isNull,
          reason: 'the mark is the iOS PRIMARY icon, so no alternate name');
      expect(AppIconStyle.defaultIcon.iosAlternateIconName, 'AppIcon',
          reason: 'the wordmark is the AppIcon alternate');
    });

    test('the picker labels say which one is the default', () {
      expect(AppIconStyle.markOnly.label, contains('default'));
      expect(AppIconStyle.defaultIcon.label, 'Logo + text');
    });
  });
}
