import 'dart:io';

import '../models/video_item.dart';
import '../utils/file_info_extractor.dart';
import 'ftp_client.dart';
import 'jellyfin_client.dart';
import 'library_folders.dart';
import 'playlist_resolver.dart';
import 'smb_client.dart';
import 'upnp_client.dart';
import 'webdav_client.dart';

/// Builds a playable [VideoItem] for a library FILE entry, per source.
///
/// Library file entries carry synthetic paths for network sources
/// (`webdav:<serverId><path>`, `ftp:<serverId><path>`,
/// `jellyfin:<serverUrl>_<itemId>`) — the real playable URL is rebuilt here
/// at tap time: WebDAV via server lookup + auth header, Jellyfin via
/// `streamUrl`, UPnP via a parent re-browse (res URLs rotate per session),
/// SMB/local directly. Returns null when a source can't be resolved
/// (no saved server, entry gone) — the caller surfaces that.
class NetworkVideoResolver {
  /// Resolves [folder] (a file entry) to a playable [VideoItem], or null.
  static Future<VideoItem?> resolve(LibraryFolder folder) async {
    // STRM pointer / M3U playlist cards resolve to the target media here.
    final playlist = await _resolvePlaylist(folder);
    if (playlist != null) return playlist;
    final info = extractFileInfo(folder.name);
    VideoItem build({
      String? path,
      String? uri,
      String? resumeKey,
      Map<String, String>? headers,
      bool allowSelfSigned = false,
      String? jellyfinServerId,
      String? jellyfinItemId,
    }) {
      return VideoItem(
        id: 'home_${folder.id}',
        title: folder.name,
        path: path,
        uri: uri,
        resumeKey: resumeKey ?? uri ?? path ?? '',
        duration: Duration.zero,
        sizeBytes: folder.videoSizeBytes,
        videoCodec: info.videoCodec,
        audioCodec: info.audioCodec,
        audioChannels: info.audioChannels,
        audioLanguage: info.audioLanguage,
        resolution: info.resolution,
        fps: info.fps,
        hdrHint: info.hdrHint,
        httpHeaders: headers ?? const {},
        allowSelfSigned: allowSelfSigned,
        jellyfinServerId: jellyfinServerId,
        jellyfinItemId: jellyfinItemId,
      );
    }

    switch (folder.source) {
      case LibraryFolderSource.files:
        final p = folder.videoPath ?? folder.path;
        return build(path: p, resumeKey: p);
      case LibraryFolderSource.smb:
        // smb:// plays via the Media3 SmbDataSource (jcifs-ng).
        final uri = folder.videoUri ??
            'smb://${folder.networkServerId}/${folder.networkShare ?? ''}/${folder.networkPath ?? ''}';
        return build(uri: uri, resumeKey: folder.path);
      case LibraryFolderSource.webdav:
        try {
          final serverId = folder.networkServerId ?? '';
          final servers = await WebDavClient.instance.listServers();
          WebDavServer? server;
          for (final s in servers) {
            if (s.id == serverId) {
              server = s;
              break;
            }
          }
          if (server == null) return null;
          String auth = '';
          try {
            auth = await WebDavClient.instance.authorizationHeader(serverId);
          } on Exception {
            auth = '';
          }
          final base = server.url.replaceAll(RegExp(r'/+$'), '');
          final path = folder.networkPath ?? '';
          return build(
            uri: '$base${_encodePath(path)}',
            resumeKey: folder.path,
            headers: auth.isEmpty ? const {} : {'Authorization': auth},
            allowSelfSigned: server.allowSelfSigned,
          );
        } on Exception {
          return null;
        }
      case LibraryFolderSource.ftp:
        final path = folder.networkPath ?? '';
        final uri = 'ftp://${folder.networkServerId}${_encodePath(path)}';
        return build(uri: uri, resumeKey: folder.path);
      case LibraryFolderSource.upnp:
        // Res URLs rotate per session and are not stored — re-browse the
        // parent container and match the entry by name (best-effort).
        try {
          final serverId = folder.networkServerId ?? '';
          final parentId = folder.parentId;
          if (parentId == null || parentId.isEmpty) return null;
          final entries = await UpnpClient.instance.browse(serverId, parentId);
          for (final e in entries) {
            if (e.name == folder.name &&
                e.url != null &&
                e.url!.isNotEmpty) {
              return build(uri: e.url, resumeKey: 'upnp:$serverId/${e.id}');
            }
          }
          return null;
        } on Exception {
          return null;
        }
      case LibraryFolderSource.jellyfin:
        try {
          final client = JellyfinClient();
          final server = await client.serverForUrl(
            folder.jellyfinServerUrl ?? '',
          );
          if (server == null || !server.isAuthenticated) return null;
          final item = JellyfinItem(
            id: folder.jellyfinItemId ?? '',
            name: folder.name,
          );
          return client.videoItem(server, item);
        } on Exception {
          return null;
        }
    }
  }

  /// Percent-encodes each path segment (mirrors `_encodePath`).
  static String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  /// Resolves a .strm/.m3u file entry to its target VideoItem, per source.
  /// Returns null for non-playlist files (and for sources without a text
  /// fetch, e.g. Jellyfin).
  static Future<VideoItem?> _resolvePlaylist(LibraryFolder folder) async {
    final name = folder.name;
    if (!PlaylistResolver.isStrmFile(name) &&
        !PlaylistResolver.isM3uFile(name)) {
      return null;
    }
    try {
      switch (folder.source) {
        case LibraryFolderSource.files:
          final p = folder.videoPath ?? folder.path;
          return await PlaylistResolver.resolveToVideoItem(
            name: name,
            selfRef: p,
            baseForRelative: 'file://$p',
            resumeKeyPrefix: folder.path,
            fetchTextAt: (ref) async {
              var f = ref;
              if (f.startsWith('file://')) f = Uri.parse(f).toFilePath();
              try {
                return PlaylistResolver.decodeText(await File(f).readAsBytes());
              } catch (_) {
                return null;
              }
            },
          );
        case LibraryFolderSource.smb:
          final serverId = folder.networkServerId ?? '';
          final share = folder.networkShare ?? '';
          final path = folder.networkPath ?? '';
          return await PlaylistResolver.resolveToVideoItem(
            name: name,
            selfRef: path,
            baseForRelative:
                'smb://$serverId/$share/${PlaylistResolver.dirOf(path)}/',
            resumeKeyPrefix: 'smb:$serverId/$share',
            fetchTextAt: (ref) async {
              var p2 = ref;
              final prefix = 'smb://$serverId/$share/';
              if (p2.startsWith(prefix)) p2 = p2.substring(prefix.length);
              return PlaylistResolver.decodeText(
                  await SmbClient.instance.fetchBytes(serverId, share, p2));
            },
          );
        case LibraryFolderSource.webdav:
          final serverId = folder.networkServerId ?? '';
          final server = (await WebDavClient.instance.listServers())
              .where((s) => s.id == serverId)
              .firstOrNull;
          if (server == null) return null;
          String auth = '';
          try {
            auth = await WebDavClient.instance.authorizationHeader(serverId);
          } on Exception {
            auth = '';
          }
          final base = server.url.replaceAll(RegExp(r'/+$'), '');
          final path = folder.networkPath ?? '';
          return await PlaylistResolver.resolveToVideoItem(
            name: name,
            selfRef: '$base${_encodePath(path)}',
            baseForRelative:
                '$base${_encodePath(PlaylistResolver.dirOf(path))}/',
            resumeKeyPrefix: 'webdav_$serverId',
            httpHeaders: auth.isEmpty ? const {} : {'Authorization': auth},
            allowSelfSigned: server.allowSelfSigned,
            fetchTextAt: (ref) async => PlaylistResolver.decodeText(
                await WebDavClient.instance.fetchUrl(serverId: serverId, url: ref)),
          );
        case LibraryFolderSource.ftp:
          final serverId = folder.networkServerId ?? '';
          final path = folder.networkPath ?? '';
          return await PlaylistResolver.resolveToVideoItem(
            name: name,
            selfRef: 'ftp://$serverId${_encodePath(path)}',
            baseForRelative:
                'ftp://$serverId${_encodePath(PlaylistResolver.dirOf(path))}/',
            resumeKeyPrefix: 'ftp_$serverId',
            fetchTextAt: (ref) async {
              var p2 = ref;
              for (final prefix in ['ftp://$serverId', 'sftp://$serverId']) {
                if (p2.startsWith(prefix)) p2 = p2.substring(prefix.length);
              }
              if (p2.startsWith('://')) p2 = p2.substring(3);
              return PlaylistResolver.decodeText(
                  await FtpClient.instance.fetchBytes(serverId, p2));
            },
          );
        case LibraryFolderSource.upnp:
          final serverId = folder.networkServerId ?? '';
          final parentId = folder.parentId;
          if (parentId == null || parentId.isEmpty) return null;
          final entries = await UpnpClient.instance.browse(serverId, parentId);
          final entry = entries
              .where((e) => e.name == name && e.url != null && e.url!.isNotEmpty)
              .firstOrNull;
          if (entry == null || entry.url == null) return null;
          return await PlaylistResolver.resolveToVideoItem(
            name: name,
            selfRef: entry.url!,
            baseForRelative: entry.url!,
            resumeKeyPrefix: 'upnp:$serverId/${entry.id}',
            fetchTextAt: (ref) async => PlaylistResolver.decodeText(
                await WebDavClient.instance.fetchUrl(url: ref)),
          );
        case LibraryFolderSource.jellyfin:
          return null;
      }
    } on Exception {
      return null;
    }
  }
}
