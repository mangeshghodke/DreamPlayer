import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A newer GitHub release of the app, with the asset matching this device.
class AvailableUpdate {
  const AvailableUpdate({
    required this.version,
    required this.installedVersion,
    required this.notes,
    required this.assetUrl,
    required this.releaseTag,
  });

  /// The GitHub tag as published (`v0.5.3`), used to link to the release page.
  final String releaseTag;

  /// Version from the release tag, without the leading `v` (`0.5.3`).
  final String version;

  /// The version currently installed (`0.5.2`).
  final String installedVersion;

  /// Release notes body, lightly de-marked-up.
  final String notes;

  /// Direct download URL for this device's ABI, or the universal APK.
  final String assetUrl;

  String get fileName => Uri.parse(assetUrl).pathSegments.last;

  /// Link to this release's page on GitHub.
  String get releasePageUrl =>
      'https://github.com/${AppUpdater._repo}/releases/tag/$releaseTag';

  /// Before 0.5.2 every published APK was signed by a throwaway CI key, so an
  /// install over one of those fails with a signature mismatch. Telling the
  /// user up front is kinder than a failed installer.
  bool get needsOneTimeUninstall => AppUpdater.compareVersions(installedVersion, '0.5.2') < 0;
}

/// Checks GitHub Releases for a newer build and performs the install.
///
/// Android only: iOS is updated by the App Store, which is not ours to drive.
/// There is no Play Core here either — the app is sideloaded, so the flow is
/// the one Seal/Sealplus use: read the release feed, download the APK, hand it
/// to the system installer.
class AppUpdater {
  AppUpdater._();

  static const _channel = MethodChannel('dreamplayer/updater');
  static const _repo = 'mangeshghodke/DreamPlayer';
  static const _latestUrl = 'https://api.github.com/repos/$_repo/releases/latest';
  static const _dirName = 'updates';

  static const _kAutoCheck = 'dreamplayer.autoUpdateCheck';
  static const _kLastCheck = 'dreamplayer.lastUpdateCheck';
  static const _kSkipped = 'dreamplayer.skippedUpdateVersion';
  static const _checkEvery = Duration(hours: 24);

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static Future<bool> autoCheckEnabled() async {
    if (!isSupported) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAutoCheck) ?? true;
  }

  static Future<void> setAutoCheck(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoCheck, enabled);
  }

  static Future<void> skipVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSkipped, version);
  }

  /// The launch-time check. Returns an update at most once per day, never
  /// throws, and stays silent when offline — an update prompt must never be
  /// the reason the app looks broken.
  static Future<AvailableUpdate?> checkIfDue() async {
    if (!isSupported) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Absent means "not asked yet": auto-check is on by default.
      if (prefs.getBool(_kAutoCheck) == false) return null;
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = prefs.getInt(_kLastCheck) ?? 0;
      if (now - last < _checkEvery.inMilliseconds) return null;
      await prefs.setInt(_kLastCheck, now);
      final update = await check();
      if (update == null) return null;
      if (prefs.getString(_kSkipped) == update.version) return null;
      return update;
    } catch (_) {
      return null;
    }
  }

  /// One GitHub Releases API call. Returns null when the installed build is
  /// current (or newer, e.g. a local build). Network failures throw, so manual
  /// checks can say "could not check" instead of falsely claiming to be up to
  /// date; [checkIfDue] swallows them.
  static Future<AvailableUpdate?> check() async {
    if (!isSupported) return null;
    final info = await PackageInfo.fromPlatform();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(_latestUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'DreamPlayer/${info.version}');
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close();
      // 403 is GitHub's rate limit and 5xx is an outage; both are "try again
      // later", not "you are up to date".
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: request.uri);
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      if (json is! Map) return null;

      final tag = (json['tag_name'] as String? ?? '').trim();
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      if (version.isEmpty) return null;
      if (compareVersions(version, info.version) <= 0) return null;

      final assets = (json['assets'] as List?) ?? const [];
      final urls = <String, String>{};
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = asset['name'] as String? ?? '';
        final url = asset['browser_download_url'] as String? ?? '';
        if (name.isNotEmpty && url.isNotEmpty) urls[name] = url;
      }
      final abi = await _currentAbi();
      final url = urls['DreamPlayer-$version-$abi.apk'] ??
          urls['DreamPlayer-$version-universal.apk'];
      if (url == null) return null;

      return AvailableUpdate(
        version: version,
        installedVersion: info.version,
        notes: cleanReleaseNotes(
          releaseNotesSection(json['body'] as String? ?? ''),
        ),
        assetUrl: url,
        releaseTag: tag,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads the APK into the app cache and returns it. The file name is
  /// kept so a retry after granting the install permission does not download
  /// the whole thing again.
  static Future<File> download(
    AvailableUpdate update, {
    required void Function(double? progress, int received, int total)
        onProgress,
    bool Function()? isCancelled,
  }) async {
    final dir = await _updateDir();
    final file = File('${dir.path}/${update.fileName}');
    if (await file.exists() && await file.length() > 0) {
      final length = await file.length();
      onProgress(1, length, length);
      await _prune(dir, keep: file.path);
      return file;
    }

    // Download beside the target and rename only when complete. A background
    // kill mid-transfer would otherwise leave a truncated file that the reuse
    // check above (`length > 0`) would happily hand to the installer.
    final part = File('${file.path}.part');
    if (await part.exists()) {
      _deleteQuietly(part);
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(update.assetUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'DreamPlayer/${update.installedVersion}');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: request.uri);
      }
      final total = response.contentLength;
      var received = 0;
      sink = part.openWrite();
      await for (final chunk in response) {
        if (isCancelled?.call() ?? false) {
          throw const _DownloadCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress(total > 0 ? received / total : null, received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received == 0) throw HttpException('Empty update download');
      if (total > 0 && received != total) {
        throw HttpException('Incomplete update download');
      }
      _deleteQuietly(file);
      await part.rename(file.path);
      onProgress(1, received, received);
      await _prune(dir, keep: file.path);
      return file;
    } catch (_) {
      await sink?.close();
      _deleteQuietly(part);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Fires the system package installer. The intent is always sent; when the
  /// "install unknown apps" grant is missing, the system installer itself
  /// shows the "For your security" popup with a Settings button (the grant is
  /// kept by the OS per app and cleared on uninstall).
  static Future<void> install(File apk) async {
    await _channel.invokeMethod<void>('installApk', {'fileName': apk.uri.pathSegments.last});
  }

  static Future<String> _currentAbi() async {
    try {
      return await _channel.invokeMethod<String>('currentAbi') ?? 'arm64-v8a';
    } on PlatformException {
      return 'arm64-v8a';
    }
  }

  static Future<Directory> _updateDir() async {
    final cache = await getTemporaryDirectory();
    return Directory('${cache.path}/$_dirName').create(recursive: true);
  }

  /// Removes APKs from previous updates — they are ~100 MB each and the cache
  /// is not a place to keep a library of them.
  static Future<void> _prune(Directory dir, {required String keep}) async {
    try {
      await for (final entry in dir.list()) {
        if (entry is File && entry.path != keep) {
          await entry.delete();
        }
      }
    } catch (_) {
      // Best effort only.
    }
  }

  /// Light de-markup for release notes: changelog headings lose their `###`,
  /// list dashes become bullets, and markdown links keep only their text.
  /// A GitHub release body is the version's changelog entry followed by the
  /// long "Download & install" guide. The prompt only has room for the entry,
  /// and the guide is not what changed, so keep the first top-level section.
  static String releaseNotesSection(String body) {
    final buffer = <String>[];
    var seenHeading = false;
    for (final line in body.split('\n')) {
      if (line.startsWith('## ')) {
        if (seenHeading) break;
        seenHeading = true;
      }
      buffer.add(line);
    }
    return buffer.join('\n');
  }

  static String cleanReleaseNotes(String body) {
    final lines = <String>[];
    for (final raw in body.split('\n')) {
      var line = raw.trimRight();
      if (line.trim().isEmpty) {
        lines.add('');
        continue;
      }
      line = line.replaceAll(RegExp(r'^#{1,6}\s*'), '');
      line = line.replaceAll(RegExp(r'^[-*]\s+'), '\u2022 ');
      line = line.replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\((?:[^()]|\([^)]*\))*\)'),
        (m) => m.group(1) ?? '',
      );
      line = line.replaceAllMapped(
        RegExp(r'\*\*([^*]+)\*\*'),
        (m) => m.group(1) ?? '',
      );
      line = line.replaceAllMapped(
        RegExp(r'`([^`]+)`'),
        (m) => m.group(1) ?? '',
      );
      lines.add(line);
    }
    var cleaned = lines.join('\n').trim();
    // The dialog shows a fixed-height scroll well; a whole changelog pasted
    // into it is not read past the first screen anyway.
    if (cleaned.length > 2000) {
      cleaned = '${cleaned.substring(0, 2000)}…';
    }
    return cleaned;
  }

  /// Numeric dotted compare. `0.5.10 > 0.5.9`, unlike a string compare.
  /// Build metadata (`+51`) and a prerelease suffix are ignored.
  static int compareVersions(String a, String b) {
    final pa = _parts(a);
    final pb = _parts(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  static List<int> _parts(String version) {
    final core = version.split('+').first.split('-').first;
    return core
        .split('.')
        .map((p) => int.tryParse(RegExp(r'^\d+').stringMatch(p) ?? '') ?? 0)
        .toList();
  }
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

void _deleteQuietly(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } catch (_) {
    // A leftover part file is pruned by the next download.
  }
}
