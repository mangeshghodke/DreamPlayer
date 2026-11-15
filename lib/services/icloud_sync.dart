import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/sync_merge.dart';
import 'continue_watching.dart';

/// iCloud cross-device sync (competitor-gap #3, iPhone ↔ iPad): watch marks,
/// resume positions and the continue-watching list travel as ONE JSON blob
/// through `NSUbiquitousKeyValueStore` (container `iCloud.com.dreamplayer.app`),
/// merged with the rules in `lib/utils/sync_merge.dart`.
///
/// iOS-ONLY by construction: on Android the service returns early before any
/// channel call (the same immunity pattern as the paywall), and the native
/// side does not exist there. The blob lives in the app's ubiquity container,
/// so it follows the user's Apple ID to a new device — no account in the app.
///
/// Flow: every 30 s while foreground + on every resume-from-background, we
/// pull the remote blob, merge it with local, apply the merged result locally
/// (writes prefs + notifies ContinueWatchingStore), and push back when the
/// local state changed. An echo guard (`_lastPushed`) skips re-applying our
/// own push when the KV store echoes it back.
class ICloudSyncService extends ChangeNotifier {
  ICloudSyncService._();

  static final ICloudSyncService instance = ICloudSyncService._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/icloudsync');
  static const EventChannel _events =
      EventChannel('dreamplayer/icloudsync/events');

  static const String prefsEnabledKey = 'dreamplayer.icloudSync';

  /// How often the blob is exchanged while the app is in the foreground.
  static const Duration syncInterval = Duration(seconds: 30);

  bool _enabled = true;
  bool _available = false;
  bool _syncing = false;
  DateTime? _lastSyncAt;
  String? _error;
  String? _lastPushed; // encoded blob we last pushed (echo guard)
  StreamSubscription<dynamic>? _sub;
  Timer? _timer;

  bool get enabled => _enabled;
  bool get available => _available;
  bool get syncing => _syncing;
  DateTime? get lastSyncAt => _lastSyncAt;
  String? get error => _error;

  /// True only on iOS — everywhere else the service is a no-op.
  bool get supported => Platform.isIOS;

  /// Loads the persisted toggle. Prefs only — no channel, safe in tests.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(prefsEnabledKey) ?? true;
    notifyListeners();
  }

  Future<void> setEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsEnabledKey, v);
    _enabled = v;
    if (v) {
      await init();
    } else {
      _timer?.cancel();
      _timer = null;
      unawaited(_sub?.cancel());
      _sub = null;
    }
    notifyListeners();
  }

  /// Starts listening + syncing. No-op off iOS or when disabled.
  Future<void> init() async {
    if (!supported || !_enabled) return;
    await load();
    if (!_enabled) return;
    try {
      final status =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('status');
      _available = status?['available'] == true;
    } catch (_) {
      _available = false;
    }
    if (!_available) {
      // Not signed in to iCloud / container not provisioned: report and stop
      // — never loop erroring.
      _error = 'iCloud unavailable (sign in to iCloud on this device)';
      notifyListeners();
      return;
    }
    _sub ??= _events.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final blob = event['blob'];
          if (blob is String && blob.isNotEmpty && blob != _lastPushed) {
            unawaited(syncNow());
          }
        }
      },
      onError: (_) {},
    );
    _timer ??= Timer.periodic(syncInterval, (_) => unawaited(syncNow()));
    await syncNow();
    notifyListeners();
  }

  /// One sync round: collect local → pull remote → merge → apply → push if
  /// the local state moved on.
  Future<void> syncNow() async {
    if (!supported || !_enabled || _syncing) return;
    _syncing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final local = collect(prefs);
      Map<dynamic, dynamic>? remote;
      try {
        remote = await _channel.invokeMethod<Map<dynamic, dynamic>>('pull');
      } catch (_) {
        remote = null;
      }
      final remoteBlob = SyncBlob.decode(
          remote != null && remote['blob'] is String
              ? remote['blob'] as String
              : null);
      final lastPushed = _lastPushed == null ? null : SyncBlob.decode(_lastPushed);
      if (remoteBlob.encode() == (lastPushed?.encode() ?? '') &&
          remoteBlob.updatedAtMs > 0) {
        // Echo of our own push — nothing new.
      } else {
        final merged = SyncBlob.merge(local, remoteBlob);
        await apply(prefs, merged);
        ContinueWatchingStore.changes.notify();
        if (merged.encode() != local.encode()) {
          final encoded = merged.capped().encode();
          try {
            await _channel.invokeMethod('push', {'blob': encoded});
            _lastPushed = encoded;
          } catch (e) {
            _error = '$e';
          }
        }
      }
      _lastSyncAt = DateTime.now();
      _error = null;
    } catch (e) {
      _error = '$e';
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// Reads the syncable state out of [prefs]. Static + prefs-injected so the
  /// whole collect path is unit-testable.
  static SyncBlob collect(SharedPreferences prefs) {
    final watched =
        (prefs.getStringList(watchedPrefsKey) ?? const []).toSet();
    final resume = <String, int>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(resumePrefsPrefix)) continue;
      final v = prefs.get(key);
      if (v is num && v > 0) {
        resume[key.substring(resumePrefsPrefix.length)] = v.toInt();
      }
    }
    final cwRaw = prefs.getString(continueWatchingPrefsKey);
    final cw = <Map<String, dynamic>>[];
    if (cwRaw != null && cwRaw.isNotEmpty) {
      try {
        final list = jsonDecode(cwRaw);
        if (list is List) {
          cw.addAll(list
              .whereType<Map>()
              .map((m) => m.cast<String, dynamic>()));
        }
      } catch (_) {}
    }
    return SyncBlob(
      watched: watched,
      resume: resume,
      cw: cw,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Writes a merged blob back into [prefs]. Static + prefs-injected so the
  /// apply path is unit-testable.
  static Future<void> apply(SharedPreferences prefs, SyncBlob blob) async {
    await prefs.setStringList(watchedPrefsKey, blob.watched.toList()..sort());
    for (final e in blob.resume.entries) {
      await prefs.setInt(resumePrefsPrefix + e.key, e.value);
    }
    await prefs.setString(
        continueWatchingPrefsKey, jsonEncode(blob.cw));
  }
}
