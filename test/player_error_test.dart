import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/screens/player_error.dart';
import 'package:dream_player/services/exo_player.dart';

void main() {
  ExoPlayerEvent ev(String code, [String? message]) => ExoPlayerEvent(
        state: 0,
        playing: false,
        buffering: false,
        ended: false,
        positionMs: 0,
        durationMs: 0,
        error: code,
        errorMessage: message,
      );

  group('friendlyPlayerError', () {
    test('maps Media3 IO error codes to actionable messages', () {
      expect(
        friendlyPlayerError(ev('ERROR_CODE_IO_BAD_HTTP_STATUS')),
        contains('Server returned an error status'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_IO_BAD_HTTP_STATUS', 'HTTP 404')),
        contains('HTTP 404'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_IO_FILE_NOT_FOUND')),
        contains('could not be accessed'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_IO_NO_PERMISSION')),
        contains('could not be accessed'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_IO_UNSPECIFIED')),
        contains('Connection interrupted'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_IO_NETWORK_CONNECTION_FAILED')),
        contains('Could not reach the server'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT')),
        contains('Could not reach the server'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_TIMEOUT')),
        contains('Could not reach the server'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED')),
        contains('Plain HTTP is blocked'),
      );
    });

    test('maps Media3 video decode errors (the HEVC/Main10 case)', () {
      // The OnHot50i / 10-bit H.265 case.
      expect(
        friendlyPlayerError(ev('ERROR_CODE_DECODING_FAILED')),
        contains('video decoder failed'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_DECODER_INIT_FAILED')),
        contains('cannot decode this video format'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_DECODER_QUERY_FAILED')),
        contains('cannot decode this video format'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_DECODING_FORMAT_UNSUPPORTED')),
        contains('cannot decode this video format'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES')),
        contains('too demanding'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_DECODING_RESOURCES_RECLAIMED')),
        contains('reclaimed the video decoder'),
      );
    });

    test('maps Media3 parse / audio errors', () {
      expect(
        friendlyPlayerError(ev('ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED')),
        contains('file format is not supported'),
      );
      expect(
        friendlyPlayerError(ev('ERROR_CODE_AUDIO_TRACK_INIT_FAILED')),
        contains('Audio output could not be initialized'),
      );
    });

    test('keeps the custom DV P5 message verbatim', () {
      const custom = 'This device cannot decode Dolby Vision Profile 5.';
      expect(
        friendlyPlayerError(ev('UnsupportedDolbyVisionProfile5', custom)),
        equals(custom),
      );
      // Falls back to a generic DV P5 message when the native side didn't
      // supply one.
      expect(
        friendlyPlayerError(ev('UnsupportedDolbyVisionProfile5')),
        contains('cannot decode Dolby Vision Profile 5'),
      );
    });

    test('unknown codes fall through to the raw "Playback failed" message', () {
      final msg = friendlyPlayerError(ev('ERROR_CODE_TOTALLY_UNKNOWN', 'boom'));
      expect(msg, contains('Playback failed'));
      expect(msg, contains('ERROR_CODE_TOTALLY_UNKNOWN'));
      expect(msg, contains('boom'));
    });
  });

  group('isRetryableIoError', () {
    test('matches every Media3 IO code worth retrying', () {
      for (final code in const [
        'ERROR_CODE_IO_UNSPECIFIED',
        'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED',
        'ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT',
        'ERROR_CODE_IO_BAD_HTTP_STATUS',
        'ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE',
        'ERROR_CODE_TIMEOUT',
      ]) {
        expect(isRetryableIoError(code), isTrue, reason: 'should retry $code');
      }
    });

    test('does NOT match decode or parse errors (those get a different path)', () {
      expect(isRetryableIoError('ERROR_CODE_DECODING_FAILED'), isFalse);
      expect(isRetryableIoError('ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED'),
          isFalse);
    });
  });

  group('isVideoDecodeError', () {
    test('matches the HEVC Main10 hardware-decode failure family', () {
      for (final code in const [
        'ERROR_CODE_DECODING_FAILED',
        'ERROR_CODE_DECODER_INIT_FAILED',
        'ERROR_CODE_DECODER_QUERY_FAILED',
        'ERROR_CODE_DECODING_FORMAT_UNSUPPORTED',
        'ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES',
        'ERROR_CODE_DECODING_RESOURCES_RECLAIMED',
      ]) {
        expect(isVideoDecodeError(code), isTrue, reason: 'should sw-fallback $code');
      }
    });

    test('does NOT match IO or parse errors', () {
      expect(isVideoDecodeError('ERROR_CODE_IO_UNSPECIFIED'), isFalse);
      expect(isVideoDecodeError('ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED'),
          isFalse);
      expect(isVideoDecodeError('UnsupportedDolbyVisionProfile5'), isFalse);
    });
  
    test('maps an unsupported Dolby Vision Profile 4 to a clear message', () {
      // iOS refuses DV P4 (single-layer IPTPQc2, broadcast format) at load.
      final msg = friendlyPlayerError(ev('UnsupportedDolbyVisionProfile4'));
      expect(msg, contains('Profile 4'));
      expect(msg, contains('broadcast'));
      expect(msg, isNot(contains('Playback failed')));
    });

    test('maps an unsupported Dolby Vision Profile 5 to a clear message', () {
      final msg = friendlyPlayerError(ev('UnsupportedDolbyVisionProfile5'));
      expect(msg.toLowerCase(), contains('profile 5'));
      expect(msg, isNot(contains('Playback failed')));
    });
});
}
