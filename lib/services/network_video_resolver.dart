import '../models/video_item.dart';
import '../utils/file_info_extractor.dart';
import 'jellyfin_client.dart';
import 'library_folders.dart';
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
}
