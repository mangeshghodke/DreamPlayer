import '../services/exo_player.dart';

/// Maps a native PlaybackException to something a user can act on.
///
/// Media3 exposes these via `errorCodeName` as `ERROR_CODE_*` strings
/// (e.g. `ERROR_CODE_DECODING_FAILED`, `ERROR_CODE_IO_BAD_HTTP_STATUS`).
/// Keeping the table here makes the mapping unit-testable in isolation.
String friendlyPlayerError(ExoPlayerEvent e) {
  final code = e.error ?? '';
  switch (code) {
    case 'ERROR_CODE_IO_BAD_HTTP_STATUS':
      final detail = e.errorMessage?.isNotEmpty == true
          ? '\n${e.errorMessage}'
          : '';
      return 'Server returned an error status for this file$detail. The '
          'source may have expired (e.g. a file handoff from a file '
          'manager) — reopen it from its source and try again.';
    case 'ERROR_CODE_IO_FILE_NOT_FOUND':
    case 'ERROR_CODE_IO_NO_PERMISSION':
      return 'The video file could not be accessed. It may have been '
          'moved, deleted, or its access permission has expired — reopen '
          'it from its source.';
    case 'ERROR_CODE_IO_UNSPECIFIED':
      return 'Connection interrupted while playing. '
          'The file may have been moved, the network may be unstable, or '
          'the server may have timed out. Try playing the file again, or '
          'check the connection to the source.';
    case 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED':
    case 'ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT':
    case 'ERROR_CODE_TIMEOUT':
      return 'Could not reach the server. Check your network connection '
          'and try again.';
    case 'ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED':
      return 'Plain HTTP is blocked for this source. Use HTTPS if the '
          'server supports it.';
    case 'UnsupportedDolbyVisionProfile5':
      return e.errorMessage?.isNotEmpty == true
          ? e.errorMessage!
          : 'This device cannot decode Dolby Vision Profile 5. Play the '
                'HDR10 or SDR version of the file, or watch it on a Dolby '
                'Vision-capable device.';
    case 'UnsupportedDolbyVisionProfile4':
      return 'Dolby Vision Profile 4 is a broadcast format that iOS does not '
          'decode. Play the HDR10 version of this video instead.';
    case 'ERROR_CODE_DECODING_FAILED':
      return 'The video decoder failed while playing this file. It may be '
          'corrupt, or the video codec (often 10-bit H.265/HEVC) is not '
          'fully supported by this device\'s hardware. Trying again with '
          'software decoding…';
    case 'ERROR_CODE_DECODING_FORMAT_UNSUPPORTED':
    case 'ERROR_CODE_DECODER_QUERY_FAILED':
    case 'ERROR_CODE_DECODER_INIT_FAILED':
      return 'This device cannot decode this video format. Common '
          'unsupported formats: 10-bit H.265/HEVC, MPEG-2, VC-1 on older '
          'devices. Trying again with software decoding…';
    case 'ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES':
      return 'This video is too demanding for this device\'s hardware '
          'decoder (high resolution, frame rate, or bit depth). Trying '
          'again with software decoding…';
    case 'ERROR_CODE_DECODING_RESOURCES_RECLAIMED':
      return 'The system reclaimed the video decoder. Reopening in '
          'software decode mode…';
    case 'ERROR_CODE_AUDIO_TRACK_INIT_FAILED':
    case 'ERROR_CODE_AUDIO_TRACK_WRITE_FAILED':
      return 'Audio output could not be initialized. '
          'Check if another app is using the audio system, or try a different audio track.';
    case 'ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED':
    case 'ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED':
    case 'ERROR_CODE_PARSING_CONTAINER_MALFORMED':
    case 'ERROR_CODE_PARSING_MANIFEST_MALFORMED':
      return 'This file format is not supported. The container (e.g. .m2ts, .ts, .vob) '
          'may use codecs this device cannot decode. Try a remuxed or re-encoded version.';
    default:
      final detail = e.errorMessage?.isNotEmpty == true
          ? '\n${e.errorMessage}'
          : '';
      return 'Playback failed ($code).$detail';
  }
}

/// Transient IO errors worth retrying (network blip). Media3 emits these
/// as `ERROR_CODE_IO_*` / `ERROR_CODE_TIMEOUT`.
bool isRetryableIoError(String code) =>
    code == 'ERROR_CODE_IO_UNSPECIFIED' ||
    code == 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED' ||
    code == 'ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT' ||
    code == 'ERROR_CODE_IO_BAD_HTTP_STATUS' ||
    code == 'ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE' ||
    code == 'ERROR_CODE_TIMEOUT';

/// Video-decode errors that point at a problem with the codec itself
/// (hardware H.265/HEVC decoders that misreport Main10 support and then
/// fail at runtime, decoder init, format unsupported, etc.). These are
/// not recoverable on the same codec path, so the player transparently
/// reopens the same file using the software decoder (the path VLC/mpv
/// use).
bool isVideoDecodeError(String code) =>
    code == 'ERROR_CODE_DECODING_FAILED' ||
    code == 'ERROR_CODE_DECODER_INIT_FAILED' ||
    code == 'ERROR_CODE_DECODER_QUERY_FAILED' ||
    code == 'ERROR_CODE_DECODING_FORMAT_UNSUPPORTED' ||
    code == 'ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES' ||
    code == 'ERROR_CODE_DECODING_RESOURCES_RECLAIMED';
