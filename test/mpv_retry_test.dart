import 'package:flutter_test/flutter_test.dart';
import 'package:dream_player/screens/player_screen.dart';

void main() {
  group('mpvErrorLooksLikeCodec', () {
    test('matches the issue-7 terminal message', () {
      expect(mpvErrorLooksLikeCodec('Could not open codec.'), isTrue);
    });

    test('matches generic decoder failures', () {
      expect(mpvErrorLooksLikeCodec('Failed to open hardware decoder'), isTrue);
      expect(mpvErrorLooksLikeCodec('hevc: error while decoding MB 12'), isTrue);
      expect(mpvErrorLooksLikeCodec('Unsupported pixel format: yuv420p10le'),
          isTrue);
      expect(mpvErrorLooksLikeCodec('avcodec send_packet failed'), isTrue);
    });

    test('rejects IO and network errors (no software retry would help)', () {
      expect(mpvErrorLooksLikeCodec('Failed to open http://192.168.1.16:8080/dav'),
          isFalse);
      expect(mpvErrorLooksLikeCodec('Connection timed out'), isFalse);
      expect(mpvErrorLooksLikeCodec('HTTP 404 Not Found'), isFalse);
      expect(mpvErrorLooksLikeCodec('No such file or directory'), isFalse);
      expect(mpvErrorLooksLikeCodec(''), isFalse);
    });

    test('is case-insensitive', () {
      expect(mpvErrorLooksLikeCodec('COULD NOT OPEN CODEC.'), isTrue);
    });
  });
}