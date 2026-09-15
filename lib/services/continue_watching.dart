import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_item.dart';

/// A video the user was watching: keeps enough metadata (title, source,
/// duration) plus the resume position so the home library can show a
/// "Continue watching" row that resumes mid-way.
class ContinueWatchingEntry {
  const ContinueWatchingEntry({
    required this.video,
    required this.position,
    required this.updatedAt,
  });

  final VideoItem video;
  final Duration position;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'video': video.toJson(),
        'positionMs': position.inMilliseconds,
        'updatedAtMs': updatedAt.millisecondsSinceEpoch,
      };

  factory ContinueWatchingEntry.fromJson(Map<String, dynamic> json) {
    return ContinueWatchingEntry(
      video: VideoItem.fromJson((json['video'] as Map).cast<String, dynamic>()),
      position:
          Duration(milliseconds: (json['positionMs'] as num?)?.toInt() ?? 0),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

/// Persists the continue-watching list (shared_preferences JSON), keyed by the
/// same stable source key ResumeStore uses (explicit resumeKey, else path, else
/// URI).
/// Wraps [ChangeNotifier] so the static store can fire the (protected)
/// `notifyListeners` from its own method.
class StoreChangeNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

class ContinueWatchingStore {
  ContinueWatchingStore._();

  static const String _prefsKey = 'dreamplayer.continueWatching';

  /// Fires whenever the persisted list changes (a save or a remove), so the
  /// home screen can reload.
  static final StoreChangeNotifier changes = StoreChangeNotifier();

  static String keyFor(VideoItem video) =>
      video.resumeKey ?? video.path ?? video.uri ?? '';

  static Future<List<ContinueWatchingEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return <ContinueWatchingEntry>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => ContinueWatchingEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(
    VideoItem video,
    Duration position,
  ) async {
    if (position.inMilliseconds < 10000) return;
    final key = keyFor(video);
    if (key.isEmpty) return;
    final entryVideo = VideoItem(
      id: video.id,
      title: video.title,
      path: video.path,
      uri: video.uri,
      resumeKey: video.resumeKey,
      duration: video.duration,
      sizeBytes: video.sizeBytes,
    );
    final all = await load();
    all.removeWhere((e) => keyFor(e.video) == key);
    all.insert(
      0,
      ContinueWatchingEntry(
        video: entryVideo,
        position: position,
        updatedAt: DateTime.now(),
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(all.map((e) => e.toJson()).toList()),
    );
    changes.notify();
  }

  static Future<void> remove(String key) async {
    if (key.isEmpty) return;
    final all = await load();
    all.removeWhere((e) => keyFor(e.video) == key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(all.map((e) => e.toJson()).toList()),
    );
    changes.notify();
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    changes.notify();
  }
}
