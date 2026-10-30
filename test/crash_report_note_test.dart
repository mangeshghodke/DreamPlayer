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

  test('existingCrashLogPaths returns only the logs that exist', () async {
    seedLogs(const ['app_debug.log', 'smb_debug.log']);
    final paths = await existingCrashLogPaths(documentsDir: docsDir);
    expect(paths, hasLength(2));
    expect(paths.any((p) => p.endsWith('app_debug.log')), isTrue);
    expect(paths.any((p) => p.endsWith('smb_debug.log')), isTrue);
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
      expect(find.textContaining('ghodke.mangesh2@gmail.com'), findsOneWidget);

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

  testWidgets('Settings shows no crash note on Android', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    await tester.pumpWidget(settingsHarness());
    await tester.pump();

    final found = await scrollToListItem(tester, find.text('App crashed?'));
    expect(found, isFalse, reason: 'note must not exist on Android');
    debugDefaultTargetPlatformOverride = null;
  });
}
