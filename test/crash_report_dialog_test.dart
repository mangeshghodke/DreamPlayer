import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/crash_report_upload.dart';
import 'package:dream_player/widgets/crash_report_dialog.dart';

void main() {
  testWidgets('dialog lists existing logs, message box and submit; without an '
      'endpoint submit fails and offers the share sheet', (tester) async {
    final dir = Directory.systemTemp.createTempSync('crashdialog');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/dreamplayer_crash.log').writeAsStringSync('[x] boom\n');
    File('${dir.path}/app_debug.log').writeAsStringSync('trace\n');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: _Opener())),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Send crash report'), findsOneWidget);
    expect(find.text('dreamplayer_crash.log'), findsOneWidget);
    expect(find.text('app_debug.log'), findsOneWidget);
    expect(find.text('What happened? (optional)'), findsOneWidget);
    expect(find.text('Submit'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNWidgets(2));

    // No CRASH_REPORT_ENDPOINT in tests → upload is not configured → the
    // submit lands in the failed state with the share-sheet fallback.
    expect(CrashReportUpload.isConfigured, isFalse);
    await tester.enterText(
      find.byType(TextField),
      'App froze when opening the SMB file',
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Upload failed'), findsOneWidget);
    expect(find.text('Use share sheet'), findsOneWidget);
  });

  testWidgets('deselecting all logs disables submit', (tester) async {
    final dir = Directory.systemTemp.createTempSync('crashdialog2');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/dreamplayer_crash.log').writeAsStringSync('x\n');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: _Opener())),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    final submit = tester.widget<FilledButton>(find.ancestor(
      of: find.text('Submit'),
      matching: find.byType(FilledButton),
    ));
    expect(submit.onPressed, isNull);
  });
}

class _Opener extends StatelessWidget {
  const _Opener();

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => showCrashReportDialog(context),
      child: const Text('open'),
    );
  }
}
