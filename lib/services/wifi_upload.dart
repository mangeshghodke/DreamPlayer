import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/upload_url.dart';
import 'download_manager.dart';

/// The WiFi upload server (competitor-gap #1): a tiny HTTP server on the
/// device's LAN address that serves an upload page, so a PC browser can push
/// videos straight INTO the phone (`http://<lan-ip>:<port>/wifi-transfer/`).
/// Uploaded files land in the download directory, so they show up in the
/// home "Downloaded" section like any other download.
///
/// The server itself is native (Kotlin `UploadServer` / Swift `UploadServer`)
/// because it must bind a real socket on 0.0.0.0; this class is only the
/// channel wrapper + persisted toggle + status + per-transfer progress. The
/// HTTP contract is raw-body POST (`/wifi-transfer/upload?name=<enc>`,
/// `Content-Length` required) - no multipart.
class WifiUploadService extends ChangeNotifier {
  WifiUploadService._();

  static final WifiUploadService instance = WifiUploadService._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/upload');

  /// Per-transfer events (`start` / `progress` / `done` / `failed`) pushed by
  /// the native servers while they stream a file. Best-effort: a missing
  /// channel (tests / desktop) just leaves the progress list empty.
  static const EventChannel _eventChannel =
      EventChannel('dreamplayer/upload_events');

  static const String prefsPortKey = 'dreamplayer.wifiUploadPort';
  static const String prefsUserKey = 'dreamplayer.wifiUploadUser';
  static const String prefsPassKey = 'dreamplayer.wifiUploadPass';

  bool _running = false;
  int _port = kWifiUploadDefaultPort;
  String _username = '';
  String _password = '';
  List<String> _urls = const [];
  String _destDir = '';
  int _receivedCount = 0;
  int _receivedBytes = 0;
  String? _error;

  /// Live transfers, newest first. Completed and failed rows stay so the
  /// screen shows what happened; clearing happens per session via
  /// [clearUploads] or when the server stops.
  final List<WifiUploadItem> _uploads = <WifiUploadItem>[];

  StreamSubscription<dynamic>? _eventsSub;

  bool get running => _running;
  int get port => _port;
  String get username => _username;
  String get password => _password;

  /// True when a username AND password are set: the browser then shows its
  /// own HTTP Basic-auth prompt before anything is served. The transfer
  /// screen REQUIRES both before it will start the server (security), so
  /// this is normally true whenever the server is running.
  bool get hasCredentials => _username.isNotEmpty && _password.isNotEmpty;
  List<String> get urls => _urls;
  String get destDir => _destDir;
  int get receivedCount => _receivedCount;
  int get receivedBytes => _receivedBytes;
  String? get error => _error;
  List<WifiUploadItem> get uploads => List<WifiUploadItem>.unmodifiable(_uploads);
  bool get hasActiveUploads => _uploads.any((u) => u.status.isActive);

  /// Loads the persisted port/credentials. Never touches the channel, so it
  /// is safe in widget tests.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _port = prefs.getInt(prefsPortKey) ?? kWifiUploadDefaultPort;
    _username = prefs.getString(prefsUserKey) ?? '';
    _password = prefs.getString(prefsPassKey) ?? '';
    notifyListeners();
  }

  /// Stores the page credentials. Does NOT restart the server: the screen
  /// debounces the restart itself, so a fast typist editing the username
  /// does not tear the live server down on every keystroke.
  Future<void> setCredentials(String username, String password) async {
    final prefs = await SharedPreferences.getInstance();
    final nextUser = username.trim();
    final nextPass = password;
    await prefs.setString(prefsUserKey, nextUser);
    await prefs.setString(prefsPassKey, nextPass);
    _username = nextUser;
    _password = nextPass;
    notifyListeners();
  }

  /// Subscribes to the native progress events. Call from a screen that shows
  /// transfers; safe to call more than once (the first subscription wins and
  /// later calls are no-ops while one is active).
  void subscribeEvents() {
    if (_eventsSub != null) return;
    try {
      _eventsSub = _eventChannel.receiveBroadcastStream().listen(
        _onNativeEvent,
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (_) {
      // No native side (desktop/tests) - progress simply stays empty.
    }
  }

  void unsubscribeEvents() {
    _eventsSub?.cancel();
    _eventsSub = null;
  }

  void _onNativeEvent(dynamic raw) {
    if (raw is! Map) return;
    final event = _asStringMap(raw);
    final type = event['type'] as String?;
    final updated = applyUploadEvent(_uploads, event);
    _uploads
      ..clear()
      ..addAll(updated);
    if (type == 'done') {
      _receivedCount += 1;
      _receivedBytes += (event['received'] as num?)?.toInt() ?? 0;
      // The file is already in the download directory; registering it is
      // what makes it show up in the home "Downloaded" grid, the drawer
      // and the Downloads screen like any other download.
      final path = event['path'] as String?;
      if (path != null && path.isNotEmpty) {
        unawaited(DownloadManager.instance.registerUploadedFile(
          path: path,
          bytes: (event['received'] as num?)?.toInt() ?? 0,
        ));
      }
    } else if (type == 'stopped') {
      _receivedCount = 0;
      _receivedBytes = 0;
    }
    notifyListeners();
  }

  static Map<String, dynamic> _asStringMap(Map raw) => raw.map(
        (k, v) => MapEntry(k.toString(), v),
      );

  /// Test-only: feed a native progress event through the real handler.
  @visibleForTesting
  void applyEventForTest(Map<String, dynamic> event) => _onNativeEvent(event);

  /// Empties the transfer list AND the summary counters. The counters are
  /// Dart-side only (fed by the progress events, and reset by the next
  /// server start), so clearing here really clears - a "clear list" button
  /// that leaves "1 files - 4.2 GB" on screen is a bug, not a summary.
  void clearUploads() {
    if (_uploads.isEmpty && _receivedCount == 0 && _receivedBytes == 0) {
      return;
    }
    _uploads.clear();
    _receivedCount = 0;
    _receivedBytes = 0;
    notifyListeners();
  }

  Future<void> setPort(int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(prefsPortKey, port);
    _port = port;
    notifyListeners();
  }

  /// Starts the server (no-op when already running). Returns true on success.
  ///
  /// [port] overrides the persisted port for THIS run: pass null to use
  /// whatever is already set (the port field on the screen is optional, so
  /// a blank field resolves to the default before it gets here).
  Future<bool> start({int? port}) async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    if (_running) return true;
    if (port != null) _port = port;
    try {
      // Uploads go to the same directory as network downloads, so the home
      // "Downloaded" grid picks them up without extra wiring.
      final destDir = await DownloadManager.instance.getDownloadDir();
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('start', {
        'port': _port,
        'destDir': destDir,
        'username': _username,
        'password': _password,
      });
      if (res == null || res['ok'] != true) {
        _error = (res?['error'] as String?) ?? 'start failed';
        _running = false;
        notifyListeners();
        return false;
      }
      _running = true;
      _error = null;
      _port = (res['port'] as num?)?.toInt() ?? _port;
      _destDir = (res['destDir'] as String?) ?? destDir;
      final addresses =
          (res['addresses'] as List?)?.whereType<String>().toList() ?? const [];
      _urls = buildUploadUrls(addresses, _port);
      notifyListeners();
      return true;
    } on PlatformException catch (e) {
      _error = e.message ?? 'start failed';
    } catch (e) {
      _error = '$e';
    }
    _running = false;
    notifyListeners();
    return false;
  }

  Future<void> stop() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {
      // Channel missing (tests/desktop) - nothing to stop.
    }
    _running = false;
    _urls = const [];
    clearUploads();
    notifyListeners();
  }

  /// Refreshes the running status (and the address list) from the native side.
  /// The received totals are NOT synced from here: they are Dart-side, fed by
  /// the progress events, so a cleared list stays cleared after a refresh.
  Future<void> refresh() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('status');
      if (res == null) return;
      _running = res['running'] == true;
      if (_running) {
        _port = (res['port'] as num?)?.toInt() ?? _port;
        _destDir = (res['destDir'] as String?) ?? _destDir;
        final addresses =
            (res['addresses'] as List?)?.whereType<String>().toList() ?? const [];
        _urls = buildUploadUrls(addresses, _port);
      }
      notifyListeners();
    } catch (_) {
      // Status is best-effort.
    }
  }
}

/// One transfer row on the WiFi transfer screen: a file arriving over the
/// LAN upload server, with the bytes the server has written so far.
class WifiUploadItem {
  WifiUploadItem({
    required this.id,
    required this.name,
    required this.total,
    required this.received,
    required this.status,
    this.error,
  });

  final String id;
  final String name;
  final int total;
  final int received;
  final WifiUploadStatus status;
  final String? error;

  /// 0..1, clamped. An unknown total (0) reports no fraction rather than a
  /// wrong one.
  double get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;

  WifiUploadItem copyWith({
    int? received,
    WifiUploadStatus? status,
    String? error,
  }) =>
      WifiUploadItem(
        id: id,
        name: name,
        total: total,
        received: received ?? this.received,
        status: status ?? this.status,
        error: error ?? this.error,
      );

  @override
  bool operator ==(Object other) =>
      other is WifiUploadItem &&
      other.id == id &&
      other.name == name &&
      other.total == total &&
      other.received == received &&
      other.status == status &&
      other.error == error;

  @override
  int get hashCode => Object.hash(id, name, total, received, status, error);
}

enum WifiUploadStatus {
  receiving,
  done,
  failed;

  bool get isActive => this == WifiUploadStatus.receiving;
}

/// Applies one native progress event to the transfer list. Pure, so the
/// whole progress model is unit-testable without a socket.
///
/// Event shapes (both native servers emit the same keys):
///   {"type":"start",   "id":..,"name":..,"total":..}
///   {"type":"progress","id":..,"received":..}
///   {"type":"done",    "id":..,"received":..,"path":..}
///   {"type":"failed",  "id":..,"error":..}
///   {"type":"cancelled"}                      - every in-flight row fails
///   {"type":"stopped"}                       - the list is cleared
List<WifiUploadItem> applyUploadEvent(
  List<WifiUploadItem> current,
  Map<String, dynamic> event,
) {
  final type = (event['type'] as String?) ?? '';
  final id = (event['id'] as String?) ?? '';
  switch (type) {
    case 'start':
      if (id.isEmpty) return current;
      final item = WifiUploadItem(
        id: id,
        name: (event['name'] as String?) ?? 'upload',
        total: (event['total'] as num?)?.toInt() ?? 0,
        received: 0,
        status: WifiUploadStatus.receiving,
      );
      return [item, ...current.where((u) => u.id != id)];
    case 'progress':
      final bytes = (event['received'] as num?)?.toInt() ?? 0;
      return current
          .map((u) => u.id == id ? u.copyWith(received: bytes) : u)
          .toList();
    case 'done':
      final bytes = (event['received'] as num?)?.toInt();
      return current
          .map((u) => u.id == id
              ? u.copyWith(
                  received: bytes ?? u.received,
                  status: WifiUploadStatus.done,
                )
              : u)
          .toList();
    case 'failed':
      return current
          .map((u) => u.id == id
              ? u.copyWith(
                  status: WifiUploadStatus.failed,
                  error: (event['error'] as String?) ?? 'failed',
                )
              : u)
          .toList();
    case 'cancelled':
      // The page's (or the notification's) Cancel button: every in-flight
      // transfer fails at once with a clear reason.
      return current
          .map((u) => u.status.isActive
              ? u.copyWith(
                  status: WifiUploadStatus.failed,
                  error: (event['error'] as String?) ?? 'Cancelled',
                )
              : u)
          .toList();
    case 'stopped':
      return <WifiUploadItem>[];
    default:
      return current;
  }
}