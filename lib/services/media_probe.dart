import '../utils/codec_info.dart';
import '../utils/remote_head_fetch.dart';
import 'package:flutter/services.dart';

class MediaProbeResult {
  const MediaProbeResult({
    this.durationMs,
    this.width,
    this.height,
    this.videoMime,
    this.audioMime,
    this.audioChannels,
    this.audioLanguage,
    this.fps,
    this.bitrate,
    this.audioSampleRate,
    this.audioBits,
    this.audioBitrate,
    this.audioTitle,
    this.audioArtist,
    this.audioAlbum,
  });

  final int? durationMs;
  final int? width;
  final int? height;
  final String? videoMime;
  final String? audioMime;
  final int? audioChannels;
  final String? audioLanguage;
  final int? fps;
  final int? bitrate;
  final int? audioSampleRate;
  final int? audioBits;
  final int? audioBitrate;
  final String? audioTitle;
  final String? audioArtist;
  final String? audioAlbum;

  /// Delegates to [friendlyResolution] so the file-info card and the player's
  /// resolution chip can never disagree about the same file.
  String? get resolutionLabel {
    if (width == null || height == null) return null;
    return friendlyResolution(width!, height!);
  }

  factory MediaProbeResult.fromMap(Map<dynamic, dynamic> m) {
    return MediaProbeResult(
      durationMs: (m['durationMs'] as num?)?.toInt(),
      width: (m['width'] as num?)?.toInt(),
      height: (m['height'] as num?)?.toInt(),
      videoMime: m['videoMime'] as String? ?? m['videoCodec'] as String?,
      audioMime: m['audioMime'] as String? ?? m['audioCodec'] as String?,
      audioChannels: (m['audioChannels'] as num?)?.toInt(),
      audioLanguage: m['audioLanguage'] as String?,
      fps: (m['fps'] as num?)?.toInt(),
      bitrate: (m['bitrate'] as num?)?.toInt(),
      audioSampleRate: (m['audioSampleRate'] as num?)?.toInt(),
      audioBits: (m['audioBits'] as num?)?.toInt(),
      audioBitrate: (m['audioBitrate'] as num?)?.toInt(),
      audioTitle: m['audioTitle'] as String?,
      audioArtist: m['audioArtist'] as String?,
      audioAlbum: m['audioAlbum'] as String?,
    );
  }
}

class MediaProbe {
  MediaProbe._();
  static final MediaProbe instance = MediaProbe._();
  static const MethodChannel _channel = MethodChannel('dreamplayer/mediaProbe');

  /// Probe a file by path/uri. For smb:// URIs the native side starts an
  /// HTTP loopback (Android) or a libsmb2 head+tail temp fetch (iOS); for
  /// http(s) URIs it probes directly with [headers]; for local/content:// it
  /// reads the file directly. [resumeKey] carries the `smb:<serverId>/...`
  /// identity so iOS can find the saved SMB credentials.
  Future<MediaProbeResult?> probe({
    String? path,
    String? uri,
    Map<String, String> headers = const {},
    bool allowSelfSigned = false,
    String? resumeKey,
  }) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('probe', {
        'path': path,
        'uri': uri,
        'headers': headers,
        'allowSelfSigned': allowSelfSigned,
        'resumeKey': resumeKey,
      });
      if (res == null || res.isEmpty) return null;
      return MediaProbeResult.fromMap(res);
    } catch (_) {
      return null;
    }
  }

  /// Probe a local temp file by absolute path.
  Future<MediaProbeResult?> probeFile(String filePath) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'probeFile',
        {'filePath': filePath},
      );
      if (res == null || res.isEmpty) return null;
      return MediaProbeResult.fromMap(res);
    } catch (_) {
      return null;
    }
  }

  /// For ftp:// or sftp:// URIs (and self-signed https) that the native reader
  /// can't open directly: download a sparse head+tail window to a temp file
  /// (the tail carries the MP4 `moov` with tags/artwork for non-fast-start
  /// files), probe it, clean up.
  Future<MediaProbeResult?> probeViaTempDownload(
    String uri, {
    Map<String, String> headers = const {},
    bool allowSelfSigned = true,
  }) async {
    final temp = await fetchHeadTailTempFile(
      uri,
      headers: headers,
      allowSelfSigned: allowSelfSigned,
    );
    if (temp == null) return null;
    try {
      return await probeFile(temp.path);
    } finally {
      try {
        if (temp.existsSync()) temp.deleteSync();
        temp.parent.deleteSync();
      } catch (_) {}
    }
  }
}
