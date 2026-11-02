import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../screens/player_screen.dart';
import '../services/default_engine_store.dart';
import '../utils/file_info_extractor.dart';

// STRM pointer files and M3U/M3U8 playlists: browsable + playable.
// The native listings include the extensions (added to the VIDEO_EXTENSIONS
// sets on both platforms), so entries reach the browsers like any video;
// tapping one resolves it here. Parsing is pure and unit-tested.

class M3uEntry {
  const M3uEntry({required this.name, required this.url});

  final String name;
  final String url;
}

class PlaylistResolver {
  PlaylistResolver._();

  static bool isStrmFile(String name) =>
      name.toLowerCase().endsWith('.strm');

  /// Directory portion of a path (`a/b/c.mkv` -> `a/b`).
  static String dirOf(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '' : path.substring(0, i);
  }

  /// Pushes the player directly for a resolved .strm/.m3u target, honoring
  /// the saved default engine (same as the Play URL flow).
  static Future<void> playResolved(BuildContext context, VideoItem item) async {
    final def = await DefaultEngineStore.load();
    if (!context.mounted) return;
    await Navigator.of(context).push(PlayerScreen.route(
      video: item,
      initialEngine: def == DefaultEngine.mpv ? PlayEngine.mpv : PlayEngine.media3,
    ));
  }

  /// utf8-decodes nullable bytes (tolerates malformed input).
  static String? decodeText(List<int>? bytes) =>
      bytes == null ? null : utf8.decode(bytes, allowMalformed: true);

  static bool isM3uFile(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.m3u') || n.endsWith('.m3u8');
  }

  /// Parses M3U/M3U8 text into entries. `#EXTINF:<dur>,<name>` sets the name;
  /// other `#` lines and blanks are skipped; URLs are NOT resolved here.
  static List<M3uEntry> parseM3u(String content) {
    final entries = <M3uEntry>[];
    String? pendingName;
    for (final rawLine in content.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF:')) {
        final comma = line.indexOf(',');
        pendingName = comma >= 0 ? line.substring(comma + 1).trim() : '';
        if (pendingName.isEmpty) pendingName = null;
        continue;
      }
      if (line.startsWith('#')) continue;
      entries.add(M3uEntry(name: pendingName ?? '', url: line));
      pendingName = null;
    }
    return entries;
  }

  /// Resolves [ref] against the playlist's own [base] (a URL or URI with a
  /// trailing directory). Absolute refs (any scheme) pass through.
  static String resolveRef(String base, String ref) {
    final r = ref.trim();
    if (r.isEmpty) return r;
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(r)) return r;
    if (base.isEmpty) return r;
    try {
      final baseUri = Uri.parse(base.endsWith('/') ? base : '$base/');
      return baseUri.resolve(r).toString();
    } catch (_) {
      return r;
    }
  }

  /// First non-empty line of a .strm file is the target URL/path.
  static String? strmTarget(String content) {
    for (final line in content.split(RegExp(r'\r?\n'))) {
      final t = line.trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }

  /// Resolves a .strm/.m3u library card to the VideoItem it points at
  /// (an .m3u card plays its first entry). Returns null when unreadable or
  /// not a playlist file — callers then fall back to the raw entry.
  static Future<VideoItem?> resolveToVideoItem({
    required String name,
    required String selfRef,
    required String baseForRelative,
    required String resumeKeyPrefix,
    required Future<String?> Function(String ref) fetchTextAt,
    Map<String, String> httpHeaders = const {},
    bool allowSelfSigned = false,
  }) async {
    if (isStrmFile(name)) {
      final text = await fetchTextAt(selfRef);
      final target = text == null ? null : strmTarget(text);
      if (target == null) return null;
      return _videoItemForResolved(
        resolved: resolveRef(baseForRelative, target),
        title: name.replaceAll(RegExp(r'\.strm$', caseSensitive: false), ''),
        fetchTextAt: fetchTextAt,
        baseForRelative: baseForRelative,
        resumeKey: 'strm:$resumeKeyPrefix/$name',
        httpHeaders: httpHeaders,
        allowSelfSigned: allowSelfSigned,
      );
    }
    if (isM3uFile(name)) {
      final text = await fetchTextAt(selfRef);
      final entries = text == null ? const <M3uEntry>[] : parseM3u(text);
      if (entries.isEmpty) return null;
      final e = entries.first;
      final resolved = resolveRef(baseForRelative, e.url);
      final label = e.name.isNotEmpty
          ? e.name
          : (Uri.tryParse(e.url)?.pathSegments.last ?? e.url);
      return _videoItemForResolved(
        resolved: resolved,
        title: label,
        fetchTextAt: fetchTextAt,
        baseForRelative: baseForRelative,
        resumeKey: 'm3u:$resumeKeyPrefix/$name',
        httpHeaders: httpHeaders,
        allowSelfSigned: allowSelfSigned,
      );
    }
    return null;
  }

  /// Handles a tapped entry that may be a .strm or .m3u/.m3u8.
  ///
  /// [fetchTextAt] reads a pointer/playlist file — pass the entry's own
  /// path/URL first, and resolved refs after (screens implement per source:
  /// local file, smb path, webdav/ftp URL, upnp URL).
  /// [baseForRelative] is the entry's own absolute URL/URI (directory form),
  /// used to resolve relative refs inside playlists/strms.
  /// [resumeKeyPrefix] scopes the strm's resume key to its source
  /// (e.g. `smb:<id>/<share>`).
  /// Returns true when the entry was a playlist/pointer and was handled.
  static Future<bool> maybeOpen({
    required BuildContext context,
    required String name,
    required String selfRef,
    required String baseForRelative,
    required String resumeKeyPrefix,
    required Future<String?> Function(String ref) fetchTextAt,
    required Future<void> Function(VideoItem item) play,
    Map<String, String> httpHeaders = const {},
    bool allowSelfSigned = false,
  }) async {
    if (isM3uFile(name)) {
      final text = await fetchTextAt(selfRef);
      final entries = text == null ? const <M3uEntry>[] : parseM3u(text);
      if (!context.mounted) return true;
      if (entries.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Empty or unreadable playlist')),
        );
        return true;
      }
      await showModalBottomSheet<void>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    final label = e.name.isNotEmpty
                        ? e.name
                        : (Uri.tryParse(e.url)?.pathSegments.last ?? e.url);
                    return ListTile(
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(label,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: e.name.isNotEmpty
                          ? Text(e.url, maxLines: 1, overflow: TextOverflow.ellipsis)
                          : null,
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        final resolved = resolveRef(baseForRelative, e.url);
                        final item = await _videoItemForResolved(
                          resolved: resolved,
                          title: e.name.isNotEmpty ? e.name : label,
                          fetchTextAt: fetchTextAt,
                          baseForRelative: baseForRelative,
                          httpHeaders: httpHeaders,
                          allowSelfSigned: allowSelfSigned,
                        );
                        if (item != null) await play(item);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
      return true;
    }
    if (isStrmFile(name)) {
      final text = await fetchTextAt(selfRef);
      final target = text == null ? null : strmTarget(text);
      if (target == null || !context.mounted) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Empty or unreadable .strm file')),
          );
        }
        return true;
      }
      final resolved = resolveRef(baseForRelative, target);
      final item = await _videoItemForResolved(
        resolved: resolved,
        title: name.replaceAll(RegExp(r'\.strm$', caseSensitive: false), ''),
        fetchTextAt: fetchTextAt,
        baseForRelative: baseForRelative,
        resumeKey: 'strm:$resumeKeyPrefix/$name',
        httpHeaders: httpHeaders,
        allowSelfSigned: allowSelfSigned,
      );
      if (item != null && context.mounted) await play(item);
      return true;
    }
    return false;
  }

  /// Builds the VideoItem for a resolved ref; follows one level of nested
  /// .strm. `file://` refs become local paths.
  static Future<VideoItem?> _videoItemForResolved({
    required String resolved,
    required String title,
    required Future<String?> Function(String ref) fetchTextAt,
    required String baseForRelative,
    String? resumeKey,
    Map<String, String> httpHeaders = const {},
    bool allowSelfSigned = false,
  }) async {
    var url = resolved;
    if (isStrmFile(url)) {
      final text = await fetchTextAt(url);
      final t = text == null ? null : strmTarget(text);
      if (t == null) return null;
      url = resolveRef(baseForRelative, t);
    }
    final uri = Uri.tryParse(url);
    final fi = extractFileInfo(title);
    if (uri != null && uri.scheme == 'file') {
      return VideoItem(
        id: 'strm_${url.hashCode}',
        title: title,
        path: uri.toFilePath(),
        resumeKey: resumeKey ?? url,
        duration: Duration.zero,
        videoCodec: fi.videoCodec,
        audioCodec: fi.audioCodec,
        resolution: fi.resolution,
        httpHeaders: httpHeaders,
        allowSelfSigned: allowSelfSigned,
      );
    }
    return VideoItem(
      id: 'strm_${url.hashCode}',
      title: title,
      uri: url,
      resumeKey: resumeKey ?? 'url:$url',
      duration: Duration.zero,
      videoCodec: fi.videoCodec,
      audioCodec: fi.audioCodec,
      resolution: fi.resolution,
      httpHeaders: httpHeaders,
      allowSelfSigned: allowSelfSigned,
    );
  }
}
