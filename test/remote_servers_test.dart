import 'package:dream_player/services/jellyfin_client.dart';
import 'package:dream_player/services/remote_servers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const webdav = MethodChannel('dreamplayer/webdav');
  const ftp = MethodChannel('dreamplayer/ftp');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(webdav, (call) async {
      if (call.method != 'listServers') return null;
      return [
        {
          'id': 'dav-1',
          'name': 'Home DAV',
          'url': 'https://nas.example/dav',
          'username': 'alice',
          'hasPassword': true,
          'allowSelfSigned': true,
        },
      ];
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

  test('aggregates safe WebDAV and Jellyfin server metadata', () async {
    await JellyfinClient().saveServers(const [
      JellyfinServer(
        name: 'Living Room',
        url: 'http://192.168.1.20:8096',
        username: 'viewer',
        token: 'secret-token',
        userId: 'user-1',
      ),
    ]);

    final servers = await RemoteServersRepository().load();
    expect(servers.map((server) => server.name),
        containsAll(['Home DAV', 'Living Room']));
    final dav = servers.firstWhere((server) => server.id == 'dav-1');
    expect(dav.username, 'alice');
    expect(dav.allowSelfSigned, isTrue);
    // The presentation model never contains passwords or access tokens.
    expect(dav.endpoint, isNot(contains('secret-token')));
  });
}
