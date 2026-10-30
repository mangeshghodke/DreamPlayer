import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The iOS privacy manifest is not optional: Apple's Program Requirements
/// (§3.3.3 B) say an app that uses a "required reason API" must declare the
/// reason in its manifest, and the manifest only counts if it is IN the built
/// bundle. A file that sits on disk but is missing from the Resources build
/// phase is exactly the trap `tool/ios_native_check.py` cannot see, so the
/// registration is pinned here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  File manifest() => File('ios/Runner/PrivacyInfo.xcprivacy');
  File pbxproj() => File('ios/Runner.xcodeproj/project.pbxproj');

  test('the privacy manifest exists and is a plist', () {
    expect(manifest().existsSync(), isTrue);
    final text = manifest().readAsStringSync();
    expect(text, contains('<plist version="1.0">'));
    expect(text, contains('NSPrivacyTracking'));
  });

  test('the manifest is copied into the app bundle', () {
    // A file reference alone is not enough — it has to be in the Runner
    // target's Resources phase or it never reaches the .app.
    expect(pbxproj().existsSync(), isTrue);
    final pbx = pbxproj().readAsStringSync();
    expect(pbx, contains('PrivacyInfo.xcprivacy in Resources'));
    expect(
      pbx,
      contains(
        'A1B2C3D4000000000000081 /* PrivacyInfo.xcprivacy in Resources */ = '
        '{isa = PBXBuildFile; fileRef = A1B2C3D4000000000000080',
      ),
    );
  });

  test('every required-reason API we use is declared', () {
    final text = manifest().readAsStringSync();
    // UserDefaults: our own Swift reads it in seven files.
    expect(text, contains('NSPrivacyAccessedAPICategoryUserDefaults'));
    // File timestamps: Dart's File.stat() in the subtitle-temp cleaner.
    expect(text, contains('NSPrivacyAccessedAPICategoryFileTimestamp'));
    // The app collects nothing and tracks nobody.
    expect(text, contains('<key>NSPrivacyCollectedDataTypes</key>'));
    expect(text, contains('<key>NSPrivacyTracking</key>'));
  });

  test('a Swift file using UserDefaults still exists (the reason is real)', () {
    // If the app ever stops touching UserDefaults, the declared reason
    // becomes stale and should be removed instead of kept for looks.
    final swift = Directory('ios/Runner')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.swift'));
    final users = swift
        .where((f) => f.readAsStringSync().contains('UserDefaults'))
        .toList();
    expect(users, isNotEmpty);
  });
}
