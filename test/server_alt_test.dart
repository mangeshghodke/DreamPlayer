import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/server_alt_store.dart';
import 'package:dream_player/utils/server_failover.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseSmbAltAddress', () {
    test('bare host defaults to port 445', () {
      expect(parseSmbAltAddress('nas.local'), (host: 'nas.local', port: 445));
      expect(parseSmbAltAddress('  192.168.1.10 '), (host: '192.168.1.10', port: 445));
    });

    test('host:port and scheme-prefixed forms parse', () {
      expect(parseSmbAltAddress('example.com:4445'), (host: 'example.com', port: 4445));
      expect(parseSmbAltAddress('http://1.2.3.4:8445'), (host: '1.2.3.4', port: 8445));
      expect(parseSmbAltAddress('https://nas.example.com/'), (host: 'nas.example.com', port: 445));
    });

    test('empty/garbage is rejected', () {
      expect(parseSmbAltAddress(''), isNull);
      expect(parseSmbAltAddress('   '), isNull);
      expect(parseSmbAltAddress('http://'), isNull);
    });
  });

  group('normalizeAltUrl', () {
    test('adds http scheme and strips trailing slashes', () {
      expect(normalizeAltUrl('example.com:8096/dav/'), 'http://example.com:8096/dav');
      expect(normalizeAltUrl('https://nas.local:8443/'), 'https://nas.local:8443');
    });

    test('empty is null', () {
      expect(normalizeAltUrl('   '), isNull);
    });
  });

  group('runWithAltFailover', () {
    test('primary success never touches the alt', () async {
      final persisted = <String?>[];
      final value = await runWithAltFailover<int>(
        primary: () async => 42,
        alt: 'alt-host',
        runAlt: (_) async => 1,
        persistAlt: (a) async => persisted.add(a),
      );
      expect(value, 42);
      expect(persisted, isEmpty);
    });

    test('primary failure runs and persists the alt', () async {
      final persisted = <String?>[];
      var altRan = false;
      final value = await runWithAltFailover<int>(
        primary: () async => throw Exception('down'),
        alt: 'alt-host:4445',
        runAlt: (a) async {
          altRan = true;
          expect(a, 'alt-host:4445');
          return 7;
        },
        persistAlt: (a) async => persisted.add(a),
      );
      expect(value, 7);
      expect(altRan, isTrue);
      expect(persisted, ['alt-host:4445']);
    });

    test('alt failure restores primary and rethrows the ORIGINAL error', () async {
      final persisted = <String?>[];
      final original = Exception('primary down');
      await expectLater(
        runWithAltFailover<int>(
          primary: () async => throw original,
          alt: 'alt',
          runAlt: (_) async => throw Exception('alt down'),
          persistAlt: (a) async => persisted.add(a),
        ),
        throwsA(original),
      );
      expect(persisted, ['alt', null]); // repoint, then restore
    });

    test('no alt -> original error, nothing persisted', () async {
      final persisted = <String?>[];
      await expectLater(
        runWithAltFailover<int>(
          primary: () async => throw Exception('down'),
          alt: null,
          runAlt: (_) async => 1,
          persistAlt: (a) async => persisted.add(a),
        ),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        runWithAltFailover<int>(
          primary: () async => throw Exception('down'),
          alt: '   ',
          runAlt: (_) async => 1,
          persistAlt: (a) async => persisted.add(a),
        ),
        throwsA(isA<Exception>()),
      );
      expect(persisted, isEmpty);
    });
  });

  group('ServerAltStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('round-trips an alternate address per source+id', () async {
      expect(await ServerAltStore.altFor('smb', 'abc'), isNull);
      await ServerAltStore.setAlt('smb', 'abc', 'nas.example.com:4445');
      await ServerAltStore.setAlt('webdav', 'xyz', 'https://pub.example.com/dav');
      expect(await ServerAltStore.altFor('smb', 'abc'), 'nas.example.com:4445');
      expect(await ServerAltStore.altFor('webdav', 'xyz'), 'https://pub.example.com/dav');
      expect(await ServerAltStore.altFor('smb', 'other'), isNull);
    });

    test('empty alt removes the entry; removeFor deletes it', () async {
      await ServerAltStore.setAlt('smb', 'abc', 'host2');
      await ServerAltStore.setAlt('smb', 'abc', '  ');
      expect(await ServerAltStore.altFor('smb', 'abc'), isNull);
      await ServerAltStore.setAlt('smb', 'abc', 'host2');
      await ServerAltStore.removeFor('smb', 'abc');
      expect(await ServerAltStore.altFor('smb', 'abc'), isNull);
    });

    test('corrupt prefs blob reads as empty', () async {
      SharedPreferences.setMockInitialValues(
          {ServerAltStore.prefsKey: '{not json'});
      expect(await ServerAltStore.altFor('smb', 'abc'), isNull);
    });
  });
}
