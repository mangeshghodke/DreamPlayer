import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/app_updater.dart';
import 'package:dream_player/widgets/update_dialog.dart';

const _update = AvailableUpdate(
  version: '0.5.5',
  installedVersion: '0.5.4',
  notes: 'Added\n\u2022 Library search',
  assetUrl:
      'https://github.com/mangeshghodke/DreamPlayer/releases/download/v0.5.5/'
      'DreamPlayer-0.5.5-arm64-v8a.apk',
      releaseTag: 'v0.5.5',
    );

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAppUpdateDialog(context, _update),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows both versions, the notes and the actions', (tester) async {
    await _pump(tester);

    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('v0.5.4'), findsOneWidget);
    expect(find.text('v0.5.5'), findsOneWidget);
    expect(find.text("What's new"), findsOneWidget);
    expect(find.textContaining('Library search'), findsOneWidget);
    expect(find.text('Download & install'), findsOneWidget);
    expect(find.text('Skip this version'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
    expect(find.text('Full changelog'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  test('install always fires the installer intent — no permission pre-check', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dreamplayer/updater'),
      (call) async {
        calls.add(call.method);
        return null;
      },
    );

    await AppUpdater.install(File('DreamPlayer-0.5.5-arm64-v8a.apk'));

    // The intent is always sent; when the "install unknown apps" grant is
    // missing the system installer itself shows the "For your security"
    // popup with its own Settings button.
    expect(calls, ['installApk']);
  });

  test('native updater has no canRequestPackageInstalls gate and the dialog '
      'has no in-app permission phase', () {
    final kt = File('android/app/src/main/kotlin/com/dreamplayer/app/AppUpdater.kt')
        .readAsStringSync();
    expect(kt, isNot(contains('canRequestPackageInstalls')));
    expect(kt, isNot(contains('permission_required')));
    expect(kt, isNot(contains('MANAGE_UNKNOWN_APP_SOURCES')));

    final dialog = File('lib/widgets/update_dialog.dart').readAsStringSync();
    expect(dialog, isNot(contains('_Phase.permission')));
    expect(dialog, isNot(contains('UpdatePermissionRequired')));
    expect(dialog, isNot(contains('openInstallPermissionSettings')));
    expect(dialog, isNot(contains("'Allow installs'")));
  });

  testWidgets('skipping remembers the version and closes', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Skip this version'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('dreamplayer.skippedUpdateVersion'), '0.5.5');
  });

  testWidgets('lays out on a phone with large text without overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _pump(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Download & install'), findsOneWidget);
  });
}
