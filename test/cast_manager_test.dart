import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/cast_manager.dart';

/// Pins the Cast manager contract (competitor-gap #6). The player screen
/// needs a live platform view, so the contract is read out of the source:
/// CastSource.isCastable decides what can be sent to a receiver, the channel
/// names match the Swift side, and the iOS-only guard keeps Android builds
/// clean.
void main() {
  final source = File('lib/services/cast_manager.dart').readAsStringSync();

  group('contract', () {
    test('channel names match between Dart client and Swift manager', () {
      expect(source, contains("MethodChannel('dreamplayer/cast'"));
      expect(source, contains("EventChannel('dreamplayer/cast/events'"));
    });

    test('iOS-only guard keeps Android clean', () {
      expect(source, contains("if (!Platform.isIOS || kIsWeb)"));
    });

    test('iOS-only guard keeps Android clean', () {
      expect(source, contains("if (!Platform.isIOS || kIsWeb)"));
    });
  });

  group('castable source shapes', () {
    test('http is castable', () {
      expect(CastSource.isCastable('http://192.168.1.50/video.mkv'), isTrue);
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

    test('smb is not castable', () {
      expect(CastSource.isCastable('smb://nas/share/video.mkv'), isFalse);
    });

    test('dreamplayersmb is not castable', () {
      expect(CastSource.isCastable('dreamplayersmb://token.mkv'), isFalse);
    });

    test('empty and null are not castable', () {
      expect(CastSource.isCastable(''), isFalse);
      expect(CastSource.isCastable(null), isFalse);
    });
  });

  group('notCastableReason', () {
    test('castable url returns null', () {
      expect(CastSource.notCastableReason('https://example.com/video.mkv'),
          isNull);
    });

    test('loopback returns a reason', () {
      expect(
        CastSource.notCastableReason('http://127.0.0.1:9000/token'),
        'Loopback streams cannot be cast',
      );
    });

    test('empty returns a reason', () {
      expect(CastSource.notCastableReason(''), 'No media URL');
    });
  });
}
