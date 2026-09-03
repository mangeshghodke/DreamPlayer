import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

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

  String? get resolutionLabel {
    if (width == null || height == null) return null;
    final w = width!;
    final h = height!;
    if (w >= 3800 || h >= 2100) return '4K';
    if (w >= 1900 || h >= 1000) return '1080p';
    if (w >= 1200 || h >= 700) return '720p';
    return '${w}x$h';
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
    );
  }
}

class MediaProbe {
  MediaProbe._();
  static final MediaProbe instance = MediaProbe._();
  static const MethodChannel _channel = MethodChannel('dreamplayer/mediaProbe');

  /// Probe a file by path/uri. For smb:// URIs the native side starts an
  /// HTTP loopback; for http(s) URIs it probes directly; for local/content://
  /// it reads the file directly.
  Future<MediaProbeResult?> probe({
    String? path,
    String? uri,
    Map<String, String> headers = const {},
    bool allowSelfSigned = false,
  }) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('probe', {
        'path': path,
        'uri': uri,
        'headers': headers,
        'allowSelfSigned': allowSelfSigned,
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

  /// For ftp:// or sftp:// URIs that MediaExtractor can't open directly:
  /// download the first [maxBytes] to a temp file, probe it, clean up.
  Future<MediaProbeResult?> probeViaTempDownload(
    String uri, {
    Map<String, String> headers = const {},
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final tempFile = File(
      '${tempDir.path}/probe_${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      final client = HttpClient();
      client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
      try {
        final request = await client.getUrl(Uri.parse(uri));
        headers.forEach(request.headers.set);
        final response = await request.close();
        final sink = tempFile.openWrite();
        int total = 0;
        await for (final chunk in response) {
          final len = chunk.length;
          if (total + len > maxBytes) {
            final remaining = maxBytes - total;
            sink.add(chunk.sublist(0, remaining));
            break;
          }
          sink.add(chunk);
          total += len;
        }
        await sink.flush();
        await sink.close();
      } finally {
        client.close(force: true);
      }
      return await probeFile(tempFile.path);
    } catch (_) {
      return null;
    } finally {
      try {
        if (tempFile.existsSync()) tempFile.deleteSync();
      } catch (_) {}
    }
  }
}
