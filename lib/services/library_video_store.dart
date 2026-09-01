import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/library_video.dart';

/// Persists the list of locally-scanned videos (from MediaStore) and provides
/// change notifications so the home screen can rebuild.
class LibraryVideoStore extends ChangeNotifier {
  LibraryVideoStore._();
  static final LibraryVideoStore instance = LibraryVideoStore._();
  static const _prefKey = 'dreamplayer.libraryVideos';

  List<LibraryVideo> _videos = const [];
  List<LibraryVideo> get videos => _videos;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// Load the persisted list from SharedPreferences.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == null || raw.isEmpty) {
      _loaded = true;
      return;
    }
    try {
      final list = jsonDecode(raw) as List;
      _videos = list
          .map((e) => LibraryVideo.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      _videos = const [];
    }
    _loaded = true;
  }

  /// Replace the persisted list and notify listeners.
  Future<void> save(List<LibraryVideo> videos) async {
    _videos = videos;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    final json = videos.map((v) => v.toJson()).toList();
    await prefs.setString(_prefKey, jsonEncode(json));
  }

  /// Merge new scan results: add new paths, remove deleted ones, keep order
  /// by dateAdded descending.
  Future<void> merge(List<LibraryVideo> scanned) async {
    final byPath = {for (final v in scanned) v.path: v};
    final existingPaths = {for (final v in _videos) v.path};

    // Start from existing, remove any that no longer exist on disk.
    final merged = _videos.where((v) => byPath.containsKey(v.path)).toList();

    // Add new entries that weren't in the old list.
    for (final v in scanned) {
      if (!existingPaths.contains(v.path)) {
        merged.add(v);
      }
    }

    // Sort by dateAdded descending (newest first).
    merged.sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
    await save(merged);
  }
}
