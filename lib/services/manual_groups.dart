import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'tmdb_client.dart';

/// A user-created grouping of library folders. Unlike auto [SeriesGroup]s
/// which are derived from name similarity, manual groups are explicit:
/// the user selects N cards on Home and collapses them into one.
class ManualGroup {
  ManualGroup({
    required this.id,
    required this.name,
    required this.folderIds,
    this.posterMeta,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  final List<String> folderIds;

  /// User-picked TMDB metadata for the group's poster (optional — picked from
  /// the group-creation dialog's TMDB search). When null, the group falls
  /// back to any member folder's cached TMDB meta.
  TmdMeta? posterMeta;

  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'folderIds': folderIds,
        if (posterMeta != null) 'posterMeta': posterMeta!.toJson(),
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory ManualGroup.fromJson(Map<String, dynamic> json) => ManualGroup(
        id: json['id'] as String,
        name: json['name'] as String,
        folderIds: (json['folderIds'] as List).cast<String>(),
        posterMeta: json['posterMeta'] != null
            ? TmdMeta.fromJson(
                (json['posterMeta'] as Map).cast<String, dynamic>())
            : null,
        createdAt: json['createdAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int)
            : DateTime.now(),
      );
}

/// Persists [ManualGroup]s in SharedPreferences (`dreamplayer.manualGroups`).
class ManualGroupsStore {
  ManualGroupsStore._();
  static final ManualGroupsStore instance = ManualGroupsStore._();

  static const String _prefsKey = 'dreamplayer.manualGroups';

  Future<List<ManualGroup>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map<String, dynamic>>()
          .map((m) => ManualGroup.fromJson(m.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<ManualGroup> groups) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(groups.map((g) => g.toJson()).toList()));
  }

  Future<void> add(ManualGroup group) async {
    final groups = await load();
    groups.add(group);
    await save(groups);
  }

  Future<void> remove(String groupId) async {
    final groups = await load();
    groups.removeWhere((g) => g.id == groupId);
    await save(groups);
  }

  /// Remove any references to [folderId] from all groups. If a group becomes
  /// empty or has only one member, it is removed entirely.
  Future<void> removeFolderId(String folderId) async {
    final groups = await load();
    var changed = false;
    for (final g in groups) {
      if (g.folderIds.remove(folderId)) changed = true;
    }
    groups.removeWhere((g) => g.folderIds.length <= 1);
    if (changed) await save(groups);
  }

  /// Sets (or clears, with null) the user-picked [TmdMeta] poster for the
  /// group [groupId] — the Fix match / Remove-info buttons on the group
  /// detail screen.
  Future<void> setPosterMeta(String groupId, TmdMeta? meta) async {
    final groups = await load();
    for (final g in groups) {
      if (g.id == groupId) {
        g.posterMeta = meta;
        break;
      }
    }
    await save(groups);
  }
}
