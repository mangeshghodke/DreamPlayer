import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/video_item.dart';
import '../utils/remote_head_fetch.dart';
import 'file_browser.dart';
import 'tmdb_client.dart';

/// Pure cache-file name for an identity key: FNV-1a 32-bit hex + a sanitized
/// tail of the key so the temp folder stays human-scannable. Exposed for
/// tests.
String thumbnailFileName(String identityKey) {
  var hash = 0x811c9dc5;
  for (final code in identityKey.codeUnits) {
    hash ^= code & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
    hash ^= (code >> 8) & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  final tail = identityKey
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
      .split('/')
      .last;
  return '${hash.toRadixString(16)}-${tail.length > 24 ? tail.substring(tail.length - 24) : tail}.img';
}

/// Embedded cover-art thumbnails (poster images stored inside the media file
/// itself - MKV attachments / MP4 `covr` atoms).
///
/// Reading them is a metadata-only operation on the native side
/// (`MediaMetadataRetriever.getEmbeddedPicture()` / AVAsset artwork), so it is
/// safe for DV/HDR content - unlike frame extraction, which returns black
/// frames on Qualcomm decoders. Files without embedded art keep the gradient
/// placeholder.
class ThumbnailStore {
  ThumbnailStore._();

  static final FileBrowserService _files = FileBrowserService.instance;

  static final Map<String, Uint8List?> _memory = {};
  static final Map<String, Future<Uint8List?>> _inFlight = {};
  static Directory? _cacheDirOverride;

  /// Test seam.
  static void setCacheDirForTesting(Directory? dir) {
    _cacheDirOverride = dir;
    _memory.clear();
    _inFlight.clear();
  }

  static Future<Directory> _cacheDir() async {
    final override = _cacheDirOverride;
    if (override != null) return override;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}cover_art');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Cover-art bytes for [video], or null when it has none. Works for ANY
  /// source: the native side reads local/content files directly, `smb://` via
  /// the loopback proxy (Android) or a libsmb2 head+tail temp file (iOS), and
  /// `http(s)://` through the URL with the item's headers. Only `ftp(s)://` and
  /// self-signed https go through a Dart-side head+tail temp download
  /// ([needsTempDownload]). Results are cached in memory and on disk keyed by
  /// the same stable identity the TMDB cache uses, so a lookup is one disk
  /// read after the first time.
  static Future<Uint8List?> artFor(VideoItem video) {
    final key = TmdStore.identityKeyFor(video);
    if (key.isEmpty) {
      return Future.value(null);
    }
    final memo = _memory[key];
    if (memo != null) return Future.value(memo);
    final pending = _inFlight[key];
    if (pending != null) return pending;
    // NOTE: block body, not arrow - `() => _inFlight.remove(key)` would
    // RETURN the removed future (the map value is this very future), making
    // whenComplete wait on itself → deadlock.
    final future = _load(key, video).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  /// Drops the in-memory negative cache so a retry can happen (e.g. after a
  /// file was re-downloaded with art attached).
  static void clearMemoryCache() => _memory.clear();

  static Future<Uint8List?> _load(String key, VideoItem video) async {
    try {
      final dir = await _cacheDir();
      final file =
          File('${dir.path}${Platform.pathSeparator}${thumbnailFileName(key)}');
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        _memory[key] = bytes.isEmpty ? null : bytes;
        return _memory[key];
      }
      // Timeout guard: a wedged channel must never stall card builds (and
      // keeps pure unit tests deterministic without an engine).
      final bytes =
          await _fetch(video).timeout(const Duration(seconds: 20));
      _memory[key] = bytes;
      if (bytes != null) {
        try {
          await file.writeAsBytes(bytes, flush: true);
        } catch (_) {}
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> _fetch(VideoItem item) async {
    final uri = item.uri ?? item.path;
    if (needsTempDownload(uri, item.allowSelfSigned)) {
      return _artViaTempDownload(item, uri!);
    }
    return _files.getThumbnail(
      path: item.path,
      uri: item.uri,
      headers: item.httpHeaders,
      allowSelfSigned: item.allowSelfSigned,
      resumeKey: item.resumeKey,
    );
  }

  /// Sources the native metadata reader cannot open itself (ftp(s), self-signed
  /// https): download a sparse head+tail window to a temp file and probe that.
  static Future<Uint8List?> _artViaTempDownload(
    VideoItem item,
    String uri,
  ) async {
    final temp = await fetchHeadTailTempFile(
      uri,
      headers: item.httpHeaders,
      allowSelfSigned: item.allowSelfSigned,
    );
    if (temp == null) return null;
    try {
      return await _files.getThumbnailFile(temp.path);
    } finally {
      try {
        if (temp.existsSync()) temp.deleteSync();
        temp.parent.deleteSync();
      } catch (_) {}
    }
  }
}
