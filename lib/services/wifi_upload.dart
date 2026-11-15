import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/upload_url.dart';
import 'download_manager.dart';

/// The WiFi upload server (competitor-gap #1): a tiny HTTP server on the
/// device's LAN address that serves an upload page, so a PC browser can push
/// videos straight INTO the phone (`http://<lan-ip>:<port>/u/<token>/`).
/// Uploaded files land in the download directory, so they show up in the
/// home "Downloaded" section like any other download.
///
/// The server itself is native (Kotlin `UploadServer` / Swift `UploadServer`)
/// because it must bind a real socket on 0.0.0.0; this class is only the
/// channel wrapper + persisted toggle + status. The HTTP contract is raw-body
/// POST (`/u/<token>/upload?name=<enc>`, `Content-Length` required) — no
/// multipart — with a per-start random token in the path.
class WifiUploadService extends ChangeNotifier {
  WifiUploadService._();

  static final WifiUploadService instance = WifiUploadService._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/upload');

  static const String prefsEnabledKey = 'dreamplayer.wifiUpload';
  static const String prefsPortKey = 'dreamplayer.wifiUploadPort';

  bool _enabled = false;
  bool _running = false;
  int _port = kWifiUploadDefaultPort;
  List<String> _urls = const [];
  String _destDir = '';
  int _receivedCount = 0;
  int _receivedBytes = 0;
  String? _error;

  bool get enabled => _enabled;
  bool get running => _running;
  int get port => _port;
  List<String> get urls => _urls;
  String get destDir => _destDir;
  int get receivedCount => _receivedCount;
  int get receivedBytes => _receivedBytes;
  String? get error => _error;

  /// Loads the persisted toggle/port. Never touches the channel, so it is
  /// safe in widget tests.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(prefsEnabledKey) ?? false;
    _port = prefs.getInt(prefsPortKey) ?? kWifiUploadDefaultPort;
    notifyListeners();
  }

  Future<void> setEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsEnabledKey, v);
    _enabled = v;
    if (v) {
      await start();
    } else {
      await stop();
    }
    notifyListeners();
  }

  Future<void> setPort(int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(prefsPortKey, port);
    _port = port;
    notifyListeners();
  }

  /// Starts the server (no-op when already running). Returns true on success.
  Future<bool> start() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    if (_running) return true;
    try {
      // Uploads go to the same directory as network downloads, so the home
      // "Downloaded" grid picks them up without extra wiring.
      final destDir = await DownloadManager.instance.getDownloadDir();
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('start', {
        'port': _port,
        'destDir': destDir,
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
      final token = (res['token'] as String?) ?? '';
      final addresses =
          (res['addresses'] as List?)?.whereType<String>().toList() ?? const [];
      _urls = buildUploadUrls(addresses, _port, token);
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
      // Channel missing (tests/desktop) — nothing to stop.
    }
    _running = false;
    _urls = const [];
    notifyListeners();
  }

  /// Refreshes the running status + received counters from the native side.
  Future<void> refresh() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('status');
      if (res == null) return;
      _running = res['running'] == true;
      _receivedCount = (res['receivedCount'] as num?)?.toInt() ?? 0;
      _receivedBytes = (res['receivedBytes'] as num?)?.toInt() ?? 0;
      if (_running) {
        _port = (res['port'] as num?)?.toInt() ?? _port;
        _destDir = (res['destDir'] as String?) ?? _destDir;
        final token = (res['token'] as String?) ?? '';
        final addresses =
            (res['addresses'] as List?)?.whereType<String>().toList() ?? const [];
        _urls = buildUploadUrls(addresses, _port, token);
      }
      notifyListeners();
    } catch (_) {
      // Status is best-effort.
    }
  }
}
