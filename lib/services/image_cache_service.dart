import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Permanent on-disk cache for TMDB images (posters, backdrops, stills,
/// cast profiles). Unlike Flutter's in-memory [ImageCache], these survive
/// app restarts. Modeled after [ThumbnailStore] but for network URLs.
class ImageCacheService {
  ImageCacheService._();

  static final ImageCacheService instance = ImageCacheService._();

  static const String _prefsKey = 'dreamplayer.permanentImageCacheEnabled';
  static const String _prefetchPrefsKey = 'dreamplayer.imageCachePrefetched';

  final Map<String, Uint8List?> _memory = {};
  final Map<String, Future<Uint8List?>> _inFlight = {};
  Directory? _cacheDir;
  bool _enabled = true;

  /// Whether permanent image caching is enabled (default: true).
  bool get enabled => _enabled;

  /// Initialize: read prefs, set up cache directory.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_prefsKey) ?? true;
    if (_enabled) {
      _cacheDir = await _dir();
    }
  }

  /// Toggle permanent image caching on/off.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, value);
    if (value) {
      _cacheDir = await _dir();
    } else {
      _memory.clear();
    }
  }

  /// Whether images have been prefetched for the first time.
  Future<bool> get prefetched async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefetchPrefsKey) ?? false;
  }

  /// Mark prefetched (called after initial bulk download).
  Future<void> markPrefetched() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefetchPrefsKey, true);
  }

  Future<Directory> _dir() async {
    if (_cacheDir != null && _cacheDir!.existsSync()) return _cacheDir!;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}image_cache');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  /// Stable file name for a URL: FNV-1a 32-bit hex + sanitized tail.
  static String _fileName(String url) {
    var hash = 0x811c9dc5;
    for (final code in url.codeUnits) {
      hash ^= code & 0xff;
      hash = (hash * 0x01000193) & 0xffffffff;
      hash ^= (code >> 8) & 0xff;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    final tail = url
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .split('/')
        .last;
    return '${hash.toRadixString(16)}-${tail.length > 32 ? tail.substring(tail.length - 32) : tail}.img';
  }

  /// Returns cached image bytes for [url], or null if not cached.
  /// Checks memory first, then disk — never hits the network.
  Future<Uint8List?> getCached(String url) async {
    if (!_enabled) return null;
    final mem = _memory[url];
    if (mem != null) return mem;
    try {
      final dir = await _dir();
      final file = File('${dir.path}${Platform.pathSeparator}${_fileName(url)}');
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _memory[url] = bytes;
          return bytes;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Download and cache [url]. Returns the bytes on success, null on failure.
  /// Deduplicates concurrent requests for the same URL.
  Future<Uint8List?> fetch(String url) async {
    if (!_enabled) return _download(url);
    final mem = _memory[url];
    if (mem != null) return mem;
    final pending = _inFlight[url];
    if (pending != null) return pending;
    final future = _fetchAndStore(url).whenComplete(() {
      _inFlight.remove(url);
    });
    _inFlight[url] = future;
    return future;
  }

  Future<Uint8List?> _fetchAndStore(String url) async {
    try {
      final bytes = await _download(url).timeout(const Duration(seconds: 15));
      _memory[url] = bytes;
      if (bytes != null && bytes.isNotEmpty) {
        try {
          final dir = await _dir();
          final file =
              File('${dir.path}${Platform.pathSeparator}${_fileName(url)}');
          await file.writeAsBytes(bytes, flush: true);
        } catch (_) {}
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> _download(String url) async {
    try {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url)).timeout(
              const Duration(seconds: 15),
            );
        final response = await request.close().timeout(
              const Duration(seconds: 15),
            );
        if (response.statusCode == 200) {
          final builder = BytesBuilder();
          await for (final chunk in response) {
            builder.add(chunk);
          }
          return builder.toBytes();
        }
        return null;
      } finally {
        client.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Pre-download all image URLs from a TMDB metadata entry. Fire-and-forget.
  void prefetchImages({
    String? posterUrl,
    String? backdropUrl,
    List<String>? stillUrls,
    List<String>? profileUrls,
  }) {
    if (!_enabled) return;
    final urls = <String>{
      ?posterUrl,
      ?backdropUrl,
      ...?stillUrls,
      ...?profileUrls,
    };
    for (final url in urls) {
      fetch(url); // fire-and-forget, deduplicates
    }
  }

  /// Total bytes on disk.
  Future<int> diskSizeBytes() async {
    try {
      final dir = await _dir();
      int total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Delete all cached images from disk and memory.
  Future<int> clear() async {
    int freed = 0;
    try {
      if (_cacheDir != null && _cacheDir!.existsSync()) {
        await for (final entity in _cacheDir!.list()) {
          if (entity is File) {
            final size = await entity.length();
            await entity.delete();
            freed += size;
          }
        }
      }
    } catch (_) {}
    _memory.clear();
    _inFlight.clear();
    _cacheDir = null;
    return freed;
  }

  /// Number of images in memory cache.
  int get memoryCount => _memory.length;

  /// Format bytes compactly: 412 B / 2.4 KB / 1.8 MB.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}
