import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/services/crash_log_share.dart';
import 'package:dream_player/screens/settings_screen.dart';
import 'package:dream_player/widgets/crash_report_note.dart';

/// The Settings "App crashed?" note — which logs exist and how they are
/// handed to the user's mail app via the system share sheet.

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);
  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getTemporaryPath() async => documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => documentsPath;
}

class PathProviderPlatformFake extends PathProviderPlatform {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;

  setUp(() {
    docsDir = Directory.systemTemp.createTempSync('crash_report_note_test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
  });

  tearDown(() {
    docsDir.deleteSync(recursive: true);
    PathProviderPlatform.instance = PathProviderPlatformFake();
  });

  void seedLogs(List<String> names) {
    for (final name in names) {
      File('${docsDir.path}/$name').writeAsStringSync('log content');
    }
  }

  test('existingCrashLogPaths returns only the logs that exist (iOS list)',
      () async {
    seedLogs(const ['app_debug.log', 'smb_debug.log', 'iap_debug.log']);
    final paths = await existingCrashLogPaths(
        documentsDir: docsDir, platform: TargetPlatform.iOS);
    expect(paths, hasLength(3));
    expect(paths.any((p) => p.endsWith('app_debug.log')), isTrue);
    expect(paths.any((p) => p.endsWith('smb_debug.log')), isTrue);
    expect(paths.any((p) => p.endsWith('iap_debug.log')), isTrue);
    expect(paths.any((p) => p.endsWith('logcat_dump.log')), isFalse);
  });

  test('existingCrashLogPaths on Android excludes iOS-only logs', () async {
    seedLogs(const [
      'dreamplayer_crash.log',
      'app_debug.log',
      'smb_debug.log',
      'iap_debug.log',
      'logcat_dump.log',
    ]);
    final paths = await existingCrashLogPaths(
        documentsDir: docsDir, platform: TargetPlatform.android);
    expect(paths, hasLength(3));
    expect(paths.any((p) => p.endsWith('dreamplayer_crash.log')), isTrue);
    expect(paths.any((p) => p.endsWith('app_debug.log')), isTrue);
    expect(paths.any((p) => p.endsWith('logcat_dump.log')), isTrue);
    expect(paths.any((p) => p.endsWith('smb_debug.log')), isFalse);
    expect(paths.any((p) => p.endsWith('iap_debug.log')), isFalse);
  });

  test('existingCrashLogPaths is empty when no log has been written', () async {
    final paths = await existingCrashLogPaths(documentsDir: docsDir);
    expect(paths, isEmpty);
  });

  test('shareCrashLogs returns null with nothing to share', () async {
    expect(shareCrashLogs(const []), completion(isNull));
  });

  testWidgets(
    'the note opens the share sheet with the existing logs attached',
    (tester) async {
      // Reset before the binding verifies foundation invariants
      // (addTearDown runs too late — after _verifyInvariants).
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final shareCalls = <Map<Object?, Object?>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        (call) async {
          if (call.method == 'share') {
            shareCalls.add(Map<Object?, Object?>.from(call.arguments as Map));
            return 'dev.fluttercommunity.plus/share/success';
          }
          return null;
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/share'),
          null,
        );
      });

      seedLogs(const ['app_debug.log', 'iap_debug.log']);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CrashReportNote())),
      );
      await tester.pumpAndSettle();

      expect(find.text('App crashed?'), findsOneWidget);
      expect(find.textContaining('dreamplayersupport@gmail.com'), findsOneWidget);

      await tester.tap(find.text('App crashed?'));
      await tester.pumpAndSettle();

      expect(shareCalls, hasLength(1));
      final args = shareCalls.single;
      expect(args['subject'], 'DreamPlayer crash report');
      final paths = (args['paths'] as List<Object?>).cast<String>().toList();
      expect(paths, hasLength(2));
      expect(paths.any((p) => p.endsWith('app_debug.log')), isTrue);
      expect(paths.any((p) => p.endsWith('iap_debug.log')), isTrue);
      expect(find.byType(SnackBar), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'the note attempts no share when no log file exists',
    (tester) async {
      // Reset before the binding verifies foundation invariants
      // (addTearDown runs too late — after _verifyInvariants).
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final shareCalls = <Map<Object?, Object?>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        (call) async {
          if (call.method == 'share') {
            shareCalls.add(Map<Object?, Object?>.from(call.arguments as Map));
            return 'dev.fluttercommunity.plus/share/success';
          }
          return null;
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/share'),
          null,
        );
      });

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CrashReportNote())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('App crashed?'));
      await tester.pumpAndSettle();
      expect(shareCalls, isEmpty);
      expect(find.textContaining('No debug logs'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  Widget settingsHarness() {
    return MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // SettingsScreen is a tab body (no own Scaffold).
      home: Scaffold(body: SettingsScreen()),
    );
  }

  /// The settings list is a virtualized ListView: walk down until the
  /// note comes into view (or the list ends).
  Future<bool> scrollToListItem(WidgetTester tester, Finder finder) async {
    const step = Offset(0, -500);
    for (var i = 0; i < 40; i++) {
      if (finder.evaluate().isNotEmpty) return true;
      final list = find.byType(ListView);
      if (list.evaluate().isEmpty) return false;
      await tester.drag(list.first, step);
      await tester.pump();
    }
    return false;
  }

  testWidgets('Settings shows the crash note below the FAQ on iOS',
      (tester) async {
    // Reset before the binding verifies foundation invariants
    // (addTearDown runs too late — after _verifyInvariants).
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    await tester.pumpWidget(settingsHarness());
    await tester.pump();

    final found = await scrollToListItem(tester, find.text('App crashed?'));
    expect(found, isTrue, reason: 'note should exist below the FAQ on iOS');
    if (tester.any(find.text('FAQ'))) {
      expect(
        tester.getRect(find.text('App crashed?')).top,
        greaterThan(tester.getRect(find.text('FAQ')).top),
      );
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Settings shows the crash note on Android too', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    await tester.pumpWidget(settingsHarness());
    await tester.pump();

    final found = await scrollToListItem(tester, find.text('App crashed?'));
    expect(found, isTrue, reason: 'note must exist on Android (logcat dump)');
    debugDefaultTargetPlatformOverride = null;
  });

  test('crashLogNamesFor is per platform', () {
    expect(crashLogNamesFor(TargetPlatform.android), contains('logcat_dump.log'));
    expect(crashLogNamesFor(TargetPlatform.android), isNot(contains('iap_debug.log')));
    expect(crashLogNamesFor(TargetPlatform.android), isNot(contains('smb_debug.log')));
    expect(crashLogNamesFor(TargetPlatform.iOS), contains('iap_debug.log'));
    expect(crashLogNamesFor(TargetPlatform.iOS), contains('smb_debug.log'));
    expect(crashLogNamesFor(TargetPlatform.iOS), isNot(contains('logcat_dump.log')));
    expect(crashLogNamesFor(TargetPlatform.android), contains('dreamplayer_crash.log'));
  });

  test('dumpLogcatIfAndroid is a no-op off Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(await dumpLogcatIfAndroid(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  test('dumpLogcatIfAndroid asks the device channel on Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dreamplayer/device'),
            (call) async {
      calls.add(call.method);
      if (call.method == 'dumpLogcat') {
        final dir = (call.arguments as Map)['dir'] as String;
        return '$dir/logcat_dump.log';
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('dreamplayer/device'), null);
      debugDefaultTargetPlatformOverride = null;
    });
    final path = await dumpLogcatIfAndroid();
    expect(calls, ['dumpLogcat']);
    expect(path, endsWith('logcat_dump.log'));
  });

  test('dumpLogcatIfAndroid swallows a missing handler', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // No mock handler registered -> MissingPluginException -> null, no throw.
    expect(await dumpLogcatIfAndroid(), isNull);
  });
}
