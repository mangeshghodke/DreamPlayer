import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/cast_manager.dart';

void main() {
  group('CastSource.isCastable', () {
    test('plain http is castable', () {
      expect(CastSource.isCastable('http://192.168.1.50:8000/video.mkv'), isTrue);
    });

    test('https is castable', () {
      expect(CastSource.isCastable('https://example.com/video.mkv'), isTrue);
    });

    test('loopback 127.0.0.1 is not castable', () {
      expect(CastSource.isCastable('http://127.0.0.1:9000/token'), isFalse);
    });

    test('localhost is not castable', () {
      expect(CastSource.isCastable('http://localhost:9000/token'), isFalse);
    });

    test('127.x.x.x is not castable', () {
      expect(CastSource.isCastable('http://127.0.0.1:9000/token'), isFalse);
    });

    test('0.0.0.0 is not castable', () {
      expect(CastSource.isCastable('http://0.0.0.0:9000/token'), isFalse);
    });

    test('smb is not castable', () {
      expect(CastSource.isCastable('smb://nas/share/video.mkv'), isFalse);
    });

    test('dreamplayersmb is not castable', () {
      expect(
        CastSource.isCastable('dreamplayersmb://token.mkv'),
        isFalse,
      );
    });

    test('ftp is not castable', () {
      expect(CastSource.isCastable('ftp://nas/share/video.mkv'), isFalse);
    });

    test('empty and null are not castable', () {
      expect(CastSource.isCastable(''), isFalse);
      expect(CastSource.isCastable(null), isFalse);
    });

    test('content is castable', () {
      expect(CastSource.isCastable('content://media/external/video/123'), isTrue);
    });

    test('file is castable', () {
      expect(CastSource.isCastable('file:///storage/emulated/0/video.mkv'), isTrue);
    });
  });

  group('CastSource.notCastableReason', () {
    test('castable url returns null', () {
      expect(CastSource.notCastableReason('https://example.com/video.mkv'), isNull);
    });

    test('loopback returns a reason', () {
      expect(
        CastSource.notCastableReason('http://127.0.0.1:9000/token'),
        'Loopback streams cannot be cast',
      );
    });

    test('custom scheme returns a reason', () {
      expect(
        CastSource.notCastableReason('smb://nas/share/video.mkv'),
        'Not a castable source',
      );
    });

    test('empty returns a reason', () {
      expect(CastSource.notCastableReason(''), 'No media URL');
    });
  });
}
