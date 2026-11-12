import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'continue_watching.dart';
import 'library_folders.dart';
import 'resume_store.dart';
import 'smb_client.dart';

/// Prunes library bookmarks and Continue-Watching entries whose SMB path was
/// deleted on the server.
///
/// HARD SAFETY RULE: only a *definitive not-found from a live server* prunes
/// ([SmbClient.isNotFound]). A network error, timeout or auth failure leaves
/// every entry alone — an offline NAS must never wipe the library or the
/// Continue Watching row.
///
/// SMB resume keys have the shape SMB-COLON-SERVERID-SLASH-SHARE-SLASH-PATH
/// (see smb_screen.dart / folder_screen.dart), so a deleted file or
/// folder is recognisable by prefix without any extra state.

/// Strips leading/trailing slashes (Dart's String.trim takes no argument).
String trimSlashes(String s) => s.replaceAll(RegExp(r'^/+|/+\$'), '');

class SmbKeyParts {
  const SmbKeyParts(this.serverId, this.share, this.path);
  final String serverId;
  final String share;
  final String path; // share-relative, no leading/trailing slash
}

/// Parses `smb:<serverId>/<share>/<path...>` into its parts. Returns null for
/// anything else (other sources, `smb_`-prefixed legacy keys, malformed).
SmbKeyParts? parseSmbResumeKey(String key) {
  if (!key.startsWith('smb:')) return null;
  final rest = key.substring(4);
  final first = rest.indexOf('/');
  if (first <= 0) return null;
  final rest2 = rest.substring(first + 1);
  final second = rest2.indexOf('/');
  if (second <= 0) return null;
  var path = rest2.substring(second + 1);
  while (path.startsWith('/')) {
    path = path.substring(1);
  }
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isEmpty) return null;
  return SmbKeyParts(rest.substring(0, first), rest2.substring(0, second), path);
}

String smbResumeKey(String serverId, String share, String path) =>
    'smb:$serverId/$share/$path';

/// CW/resume keys that live DIRECTLY inside [dirPath] on this server/share
/// and whose file name is not in [listingNames] — i.e. deleted on the server.
/// Keys in subfolders are untouched (they get pruned when their own folder is
/// listed or probed).
List<String> missingFileKeys({
  required String serverId,
  required String share,
  required String dirPath,
  required Set<String> listingNames,
  required Iterable<String> allKeys,
}) {
  final dir = trimSlashes(dirPath);
  final prefix = dir.isEmpty ? 'smb:$serverId/$share/' : 'smb:$serverId/$share/$dir/';
  final out = <String>[];
  for (final key in allKeys) {
    if (!key.startsWith(prefix)) continue;
    final name = key.substring(prefix.length);
    if (name.isEmpty || name.contains('/')) continue;
    if (!listingNames.contains(name)) out.add(key);
  }
  return out;
}

/// All keys under a (possibly deleted) folder path, recursively.
List<String> keysUnderFolder(String folderKeyPrefix, Iterable<String> allKeys) =>
    allKeys.where((k) => k.startsWith(folderKeyPrefix)).toList();

/// Removes one key from both stores. Never throws.
Future<void> removeStoredEntry(String key) async {
  if (key.isEmpty) return;
  try {
    await ContinueWatchingStore.remove(key);
  } catch (_) {}
  try {
    await ResumeStore.clear(key);
    await ResumeStore.clear(key, engine: 'media3');
    await ResumeStore.clear(key, engine: 'mpv');
  } catch (_) {}
}

typedef StatPathFn = Future<({bool exists, bool isDirectory})> Function(
  String serverId,
  String share,
  String path,
);

class NetworkPrune {
  NetworkPrune._();

  static const String _lastRunKey = 'dreamplayer.lastNetPruneAt';
  static const Duration throttle = Duration(minutes: 10);
  static const int maxConcurrentStats = 4;

  /// Reconciles Continue Watching against a fresh SUCCESSFUL listing of
  /// [dirPath]: entries for direct-child files no longer present are removed
  /// (with their resume positions). Free — the listing already happened.
  /// Returns the number of entries pruned. Never throws.
  static Future<int> pruneMissingFromListing({
    required String serverId,
    required String share,
    required String dirPath,
    required List<SmbEntry> entries,
  }) async {
    try {
      final names = entries.map((e) => e.name).toSet();
      final cw = await ContinueWatchingStore.load();
      final keys = cw.map((e) => ContinueWatchingStore.keyFor(e.video)).toList();
      final missing = missingFileKeys(
        serverId: serverId,
        share: share,
        dirPath: dirPath,
        listingNames: names,
        allKeys: keys,
      );
      for (final key in missing) {
        await removeStoredEntry(key);
      }
      return missing.length;
    } catch (_) {
      return 0;
    }
  }

  /// Called when listing [folder] on the SMB server failed with
  /// `smb_not_found`: the folder itself is gone, so the library bookmark and
  /// every stored entry under it are removed. Any other error is a no-op.
  /// Returns true when something was pruned. Never throws.
  static Future<bool> pruneBookmarkIfGone(LibraryFolder folder) async {
    if (folder.source != LibraryFolderSource.smb) return false;
    final serverId = folder.networkServerId;
    final share = folder.networkShare;
    if (serverId == null || share == null) return false;
    final path = trimSlashes(folder.networkPath ?? folder.path);
    final prefix = path.isEmpty
        ? 'smb:$serverId/$share/'
        : 'smb:$serverId/$share/$path';
    try {
      await LibraryFoldersStore.remove(folder.id);
      final cw = await ContinueWatchingStore.load();
      final keys = cw.map((e) => ContinueWatchingStore.keyFor(e.video)).toList();
      // The folder is gone, so everything under it is gone (recursive).
      final under = keysUnderFolder(prefix, keys);
      for (final key in under) {
        await removeStoredEntry(key);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Background sweep for the home screen: stats every SMB continue-watching
  /// file whose server is online and prunes the ones the server reports gone.
  /// Throttled (at most once per [throttle]) and never runs against an offline
  /// server. Never throws.
  static Future<void> verifyNetworkContinueWatching({
    SmbClient? smb,
    StatPathFn? stat,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = prefs.getInt(_lastRunKey) ?? 0;
      if (now - last < throttle.inMilliseconds) return;
      await prefs.setInt(_lastRunKey, now);

      final cw = await ContinueWatchingStore.load();
      final keys = cw
          .map((e) => ContinueWatchingStore.keyFor(e.video))
          .map(parseSmbResumeKey)
          .whereType<SmbKeyParts>()
          .toList();
      if (keys.isEmpty) return;

      final client = smb ?? SmbClient.instance;
      final statFn = stat ?? client.statPath;
      final servers = await client.listServers();
      final byId = {for (final s in servers) s.id: s};

      // Group by server; only stat servers that answer a port probe.
      final byServer = <String, List<SmbKeyParts>>{};
      for (final k in keys) {
        (byServer[k.serverId] ??= []).add(k);
      }
      for (final entry in byServer.entries) {
        final server = byId[entry.key];
        if (server == null) continue;
        final online = await client.checkServer(server.host, server.port);
        if (!online) continue; // offline NAS: prune NOTHING
        // Concurrency-limited stats.
        final queue = List<SmbKeyParts>.of(entry.value);
        Future<void> worker() async {
          while (queue.isNotEmpty) {
            final k = queue.removeAt(0);
            try {
              final r = await statFn(k.serverId, k.share, k.path);
              if (!r.exists) await removeStoredEntry(smbResumeKey(k.serverId, k.share, k.path));
            } on PlatformException catch (e) {
              // smb_not_found is handled inside statPath (returns exists:false);
              // anything else (offline mid-sweep, auth) prunes nothing.
              if (SmbClient.isNotFound(e)) {
                await removeStoredEntry(smbResumeKey(k.serverId, k.share, k.path));
              }
            } catch (_) {}
          }
        }
        await Future.wait(List.generate(
          maxConcurrentStats.clamp(1, queue.length),
          (_) => worker(),
        ));
      }
    } catch (_) {}
  }
}
