import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_item.dart';
import 'smb_client.dart';

const String _kPrefsKey = 'dreamplayer.downloads';
const MethodChannel _channel = MethodChannel('dreamplayer/download');

enum DownloadStatus { queued, downloading, completed, failed, cancelled }

class DownloadJob {
  DownloadJob({
    required this.id,
    required this.title,
    required this.sourceUri,
    required this.sourceType,
    this.httpHeaders = const {},
    this.allowSelfSigned = false,
    this.totalBytes = -1,
    this.bytesCopied = 0,
    this.status = DownloadStatus.queued,
    this.destPath = '',
    this.error,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String title;
  String sourceUri;
  String sourceType;
  Map<String, String> httpHeaders;
  bool allowSelfSigned;
  int totalBytes;
  int bytesCopied;
  DownloadStatus status;
  String destPath;
  String? error;
  DateTime createdAt;

  /// Transient: SMB loopback HTTP bridge token. Not persisted — only valid
  /// while the app process is alive. Cleaned up in [_downloadFile]'s finally.
  String? loopbackToken;

  double get progress =>
      totalBytes > 0 ? (bytesCopied / totalBytes).clamp(0.0, 1.0) : 0.0;

  String get fileSizeLabel => _formatSize(totalBytes);
  String get downloadedLabel => _formatSize(bytesCopied);

  String get statusLabel => switch (status) {
        DownloadStatus.queued => 'Queued',
        DownloadStatus.downloading => 'Downloading\u2026',
        DownloadStatus.completed => 'Completed',
        DownloadStatus.failed => 'Failed',
        DownloadStatus.cancelled => 'Cancelled',
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'sourceUri': sourceUri,
        'sourceType': sourceType,
        'httpHeaders': httpHeaders,
        'allowSelfSigned': allowSelfSigned,
        'totalBytes': totalBytes,
        'bytesCopied': bytesCopied,
        'status': status.index,
        'destPath': destPath,
        'error': error,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory DownloadJob.fromJson(Map<String, dynamic> json) => DownloadJob(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        sourceUri: json['sourceUri'] as String? ?? '',
        sourceType: json['sourceType'] as String? ?? 'http',
        httpHeaders:
            Map<String, String>.from(json['httpHeaders'] as Map? ?? {}),
        allowSelfSigned: json['allowSelfSigned'] == true,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? -1,
        bytesCopied: (json['bytesCopied'] as num?)?.toInt() ?? 0,
        status: DownloadStatus.values[(json['status'] as num?)?.toInt() ?? 0],
        destPath: json['destPath'] as String? ?? '',
        error: json['error'] as String?,
        createdAt: json['createdAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int)
            : null,
      );
}

String _formatSize(int bytes) {
  if (bytes < 0) return '?';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final instance = DownloadManager._();

  final List<DownloadJob> downloads = [];
  bool _initialized = false;
  Completer<void>? _activeCompleter;

  DownloadJob? get activeJob =>
      downloads.cast<DownloadJob?>().firstWhere(
            (j) => j?.status == DownloadStatus.downloading,
            orElse: () => null,
          );

  bool get isDownloading => activeJob != null;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onCancelFromNotification') {
        final jobId = call.arguments as String?;
        if (jobId != null) cancelDownload(jobId);
      }
    });
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kPrefsKey) ?? [];
    downloads.clear();
    for (final s in raw) {
      try {
        downloads.add(DownloadJob.fromJson(
            jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> startDownload(VideoItem video) async {
    final dir = await _channel.invokeMethod<String>('getDownloadDir');
    if (dir == null) throw Exception('Could not get download directory');
    final id = _jobId(video);
    final existing = downloads.where((j) => j.id == id).firstOrNull;
    if (existing != null) {
      if (existing.status == DownloadStatus.downloading ||
          existing.status == DownloadStatus.queued) {
        return;
      }
      downloads.remove(existing);
    }
    // For SMB, sourceUri must be the smb:// URI with serverId (from resumeKey).
    // video.path = smb://<share>/<file> (no serverId)
    // video.resumeKey = smb:<serverId>/<share>/<file>
    String sourceUri;
    final src = _sourceType(video);
    if (src == 'smb') {
      final rk = video.resumeKey ?? '';
      if (rk.startsWith('smb:')) {
        // Convert "smb:<serverId>/<share>/<path>" → "smb://<serverId>/<share>/<path>"
        sourceUri = 'smb://${rk.substring(4)}';
      } else {
        sourceUri = video.path ?? video.uri ?? '';
      }
    } else {
      sourceUri = video.uri ?? '';
    }
    final ext = _extension(video.title, video.uri);
    final safeName = _safeFileName(video.title);
    final destPath = '$dir/$safeName$ext';
    final job = DownloadJob(
      id: id,
      title: video.title,
      sourceUri: sourceUri,
      sourceType: src,
      httpHeaders: video.httpHeaders,
      allowSelfSigned: video.allowSelfSigned,
      totalBytes: video.sizeBytes ?? -1,
      destPath: destPath,
    );
    downloads.insert(0, job);
    await _save();
    notifyListeners();
    _startForeground(job);
    _downloadFile(job);
  }

  Future<void> cancelDownload(String jobId) async {
    final job = downloads.where((j) => j.id == jobId).firstOrNull;
    if (job == null) {
      return;
    }
    if (job.status != DownloadStatus.downloading &&
        job.status != DownloadStatus.queued) {
      return;
    }
    job.status = DownloadStatus.cancelled;
    _activeCompleter?.complete();
    _activeCompleter = null;
    try {
      final f = File(job.destPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    await _channel.invokeMethod('stopService');
    await _save();
    notifyListeners();
  }

  Future<void> deleteDownload(String jobId) async {
    final job = downloads.where((j) => j.id == jobId).firstOrNull;
    if (job == null) return;
    if (job.status == DownloadStatus.downloading ||
        job.status == DownloadStatus.queued) {
      await cancelDownload(jobId);
    }
    try {
      final f = File(job.destPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    downloads.removeWhere((j) => j.id == jobId);
    await _save();
    notifyListeners();
  }

  bool isDownloaded(String resumeKey) {
    final id = 'dl_${resumeKey.hashCode.toRadixString(16)}';
    return downloads
        .any((j) => j.id == id && j.status == DownloadStatus.completed);
  }

  String? localPathFor(String resumeKey) {
    final id = 'dl_${resumeKey.hashCode.toRadixString(16)}';
    final job = downloads
        .where((j) => j.id == id && j.status == DownloadStatus.completed)
        .firstOrNull;
    if (job != null && File(job.destPath).existsSync()) return job.destPath;
    return null;
  }

  // -- private --

  Future<void> _startForeground(DownloadJob job) async {
    try {
      await _channel.invokeMethod('startService', {
        'title': job.title,
        'totalBytes': job.totalBytes,
        'jobId': job.id,
      });
    } catch (_) {}
  }

  Future<void> _updateNotification(DownloadJob job) async {
    try {
      await _channel.invokeMethod('updateProgress', {
        'title': job.title,
        'bytesCopied': job.bytesCopied,
        'totalBytes': job.totalBytes,
      });
    } catch (_) {}
  }

  /// Resolves an `smb://<serverId>/<share>/<path>` URI to a loopback HTTP URL
  /// via [SmbClient.startLoopback]. Stores the token on [job] so
  /// [_stopSmbLoopback] can tear it down later.
  Future<String> _startSmbLoopback(DownloadJob job) async {
    final String rawUri;
    if (job.sourceUri.startsWith('smb://')) {
      rawUri = job.sourceUri;
    } else {
      // Fallback: shouldn't happen for SMB jobs
      throw Exception('Not an SMB source: ${job.sourceUri}');
    }
    final u = Uri.parse(rawUri);
    final serverId = u.host;
    final seg = u.pathSegments;
    if (serverId.isEmpty || seg.isEmpty) {
      throw Exception('Malformed SMB URI: $rawUri');
    }
    final share = seg.first;
    final path = seg.length > 1 ? seg.skip(1).join('/') : '';
    final url = await SmbClient.instance.startLoopback(serverId, share, path);
    if (url.isEmpty) throw Exception('Could not connect to SMB server');
    job.loopbackToken = Uri.parse(url).pathSegments.firstOrNull;
    return url;
  }

  /// Tears down the loopback bridge previously started by [_startSmbLoopback].
  Future<void> _stopSmbLoopback(DownloadJob job) async {
    final t = job.loopbackToken;
    job.loopbackToken = null;
    if (t == null || t.isEmpty) return;
    try {
      await SmbClient.instance.stopLoopback(t);
    } catch (_) {}
  }

  Future<void> _downloadFile(DownloadJob job) async {
    job.status = DownloadStatus.downloading;
    notifyListeners();
    final completer = Completer<void>();
    _activeCompleter = completer;
    try {
      // SMB files go through the HTTP loopback proxy.
      String? loopbackUrl;
      if (job.sourceType == 'smb' && job.sourceUri.startsWith('smb://')) {
        loopbackUrl = await _startSmbLoopback(job);
        if (completer.isCompleted) return;
      }

      final uri = Uri.parse(loopbackUrl ?? job.sourceUri);
      final client = HttpClient();
      client.badCertificateCallback = (cert, host, port) => job.allowSelfSigned;
      client.connectionTimeout = const Duration(seconds: 30);
      final request = await client.getUrl(uri);
      for (final e in job.httpHeaders.entries) {
        request.headers.set(e.key, e.value);
      }
      final response = await request.close();
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final contentLength = response.contentLength;
      if (contentLength > 0) job.totalBytes = contentLength;
      final file = File(job.destPath);
      final sink = file.openWrite();
      int lastNotifyBytes = 0;
      await for (final chunk in response) {
        if (completer.isCompleted) break;
        sink.add(chunk);
        job.bytesCopied += chunk.length;
        if (job.bytesCopied - lastNotifyBytes > 256 * 1024) {
          lastNotifyBytes = job.bytesCopied;
          await _updateNotification(job);
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      if (completer.isCompleted) {
        try {
          file.deleteSync();
        } catch (_) {}
        return;
      }
      job.status = DownloadStatus.completed;
      await _updateNotification(job);
      try {
        await _channel.invokeMethod('stopService');
      } catch (_) {}
    } catch (e) {
      if (!completer.isCompleted) {
        job.status = DownloadStatus.failed;
        job.error = e.toString();
        try {
          await _channel.invokeMethod('stopService');
        } catch (_) {}
      }
    } finally {
      await _stopSmbLoopback(job);
      await _save();
      notifyListeners();
      if (!completer.isCompleted) completer.complete();
      _activeCompleter = null;
    }
  }

  String _jobId(VideoItem v) {
    final key = v.resumeKey ?? v.path ?? v.uri ?? '';
    return 'dl_${key.hashCode.toRadixString(16)}';
  }

  String _sourceType(VideoItem v) {
    final src = v.playbackSource;
    if (src == null) return 'http';
    return switch (src) {
      PlaybackSource.webdav => 'webdav',
      PlaybackSource.jellyfin => 'jellyfin',
      PlaybackSource.smb => 'smb',
      PlaybackSource.cxSmb => 'smb',
      PlaybackSource.filesSmb => 'smb',
      PlaybackSource.ftp => 'ftp',
      PlaybackSource.network => 'network',
      PlaybackSource.files => 'local',
    };
  }

  String _extension(String title, String? uri) {
    if (uri != null) {
      final uriPath = Uri.tryParse(uri)?.path ?? '';
      final dot = uriPath.lastIndexOf('.');
      if (dot >= 0) return uriPath.substring(dot);
    }
    final dot = title.lastIndexOf('.');
    if (dot >= 0) return title.substring(dot);
    return '.mp4';
  }

  String _safeFileName(String name) => name
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = downloads.map((j) => jsonEncode(j.toJson())).toList();
    await prefs.setStringList(_kPrefsKey, encoded);
  }
}
