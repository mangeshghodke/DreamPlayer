import 'package:dream_player/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const webdav = MethodChannel('dreamplayer/webdav');
  const ftp = MethodChannel('dreamplayer/ftp');

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'dreamplayer.tmdbHintShown': true,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webdav, (call) async {
      if (call.method == 'listServers') {
        return [
          {
            'id': 'dav-home',
            'name': 'Home DAV',
            'url': 'https://nas.example/dav',
            'username': 'alice',
            'hasPassword': true,
          },
        ];
      }
      if (call.method == 'listDirectory') return <Object>[];
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ftp, (call) async => <Object>[]);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webdav, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ftp, null);
  });

  testWidgets('saved server is visible on Home and opens its root',
      (tester) async {
    await tester.pumpWidget(const DreamPlayerApp());
    await tester.pumpAndSettle();

    expect(find.text('Remote servers'), findsOneWidget);
    expect(find.text('Home DAV'), findsOneWidget);

    await tester.tap(find.text('Home DAV'));
    await tester.pumpAndSettle();

    expect(find.text('Home DAV'), findsOneWidget);
    expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
    expect(find.text('Nothing here'), findsOneWidget);
  });
}
