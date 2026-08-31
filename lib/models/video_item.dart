import '../utils/codec_info.dart';
import 'hdr_format.dart';

/// A chapter from the container or the media server (MKV `Chapters`,
/// Jellyfin `MediaSources[].Chapters`).
class VideoChapter {
  const VideoChapter({
    required this.title,
    required this.startMs,
    this.endMs,
  });

  final String title;
  final int startMs;
  final int? endMs;

  Map<String, dynamic> toJson() => {
        'title': title,
        'startMs': startMs,
        if (endMs != null) 'endMs': endMs,
      };

  factory VideoChapter.fromJson(Map<String, dynamic> json) => VideoChapter(
        title: json['title'] as String? ?? 'Chapter',
        startMs: (json['startMs'] as num?)?.toInt() ?? 0,
        endMs: (json['endMs'] as num?)?.toInt(),
      );
}

/// An external subtitle track from a media server (e.g. Jellyfin).
class VideoExternalSub {
  const VideoExternalSub({
    required this.uri,
    required this.label,
    this.language = '',
    this.mimeType = 'application/x-subrip',
    this.isDefault = false,
  });

  final String uri;
  final String label;
  final String language;
  final String mimeType;
  final bool isDefault;

  Map<String, dynamic> toJson() => {
        'uri': uri,
        'label': label,
        'language': language,
        'mimeType': mimeType,
        'isDefault': isDefault,
      };

  factory VideoExternalSub.fromJson(Map<String, dynamic> json) =>
      VideoExternalSub(
        uri: json['uri'] as String? ?? '',
        label: json['label'] as String? ?? '',
        language: json['language'] as String? ?? '',
        mimeType: json['mimeType'] as String? ?? 'application/x-subrip',
        isDefault: (json['isDefault'] as bool?) ?? false,
      );

  /// Returns a copy with the same fields but [isDefault] forced to true.
  /// Used to mark a track as the default selection without rebuilding the
  /// whole object.
  VideoExternalSub withDefault({required bool isDefault}) => VideoExternalSub(
        uri: uri,
        label: label,
        language: language,
        mimeType: mimeType,
        isDefault: isDefault,
      );
}

/// Marks the first entry as the default selection when no entry in the
/// list already carries `isDefault = true`. Enforces the
/// **"external > embedded always"** priority rule across every source
/// that builds external-sub lists (Jellyfin DeliveryUrls, DLNA
/// `externalSubs`, future media servers).
///
/// Why this is needed: media servers don't always flag a sidecar as
/// the default track — Jellyfin only sets `IsDefault` for explicitly
/// marked tracks, and most DLNA servers don't fill the field at all.
/// Without a `SELECTION_FLAG_DEFAULT` marker on any external track, the
/// engine picks the container's embedded PGS/ASS track instead — almost
/// always the wrong choice when a better external file is sitting next
/// to the video. Promoting the first external to default fixes this for
/// every source in one place.
///
/// When [subs] is empty, returns it unchanged so the engine falls back
/// to embedded (which the engine then auto-selects as default).
List<VideoExternalSub> promoteFirstExternalAsDefault(
  List<VideoExternalSub> subs,
) {
  if (subs.isEmpty) return subs;
  final anyDefault = subs.any((s) => s.isDefault);
  if (anyDefault) return subs;
  return [
    subs.first.withDefault(isDefault: true),
    ...subs.skip(1),
  ];
}

/// Where a video came from, derived from the source-specific [VideoItem]
/// identifiers so the UI can show where playback is served from.
enum PlaybackSource {
  webdav('WebDAV'),
  ftp('FTP'),
  cxSmb('CX SMB'),
  filesSmb('Files / SMB'),
  smb('SMB'),
  jellyfin('Jellyfin'),
  files('Files'),
  network('Network');

  const PlaybackSource(this.label);

  final String label;
}

class VideoItem {
  const VideoItem({
    required this.id,
    required this.title,
    this.path,
    this.uri,
    this.resumeKey,
    required this.duration,
    this.sizeBytes,
    this.resolution,
    this.videoCodec,
    this.hdrHint,
    this.audioCodec,
    this.audioProfile,
    this.audioChannels,
    this.subtitleUri,
    this.httpHeaders = const {},
    this.allowSelfSigned = false,
    this.jellyfinServerId,
    this.jellyfinItemId,
    this.webdavServerId,
    this.ftpServerId,
    this.externalSubtitles = const [],
    this.chapters = const [],
    this.isTranscoded = false,
  });

  final String id;
  final String title;

  /// Absolute file path, or `null` when only a URI is available.
  final String? path;

  /// e.g. a `content://` URI handed over from an "Open with" intent.
  final String? uri;

  /// HTTP request headers to send when loading [uri] (e.g. WebDAV Basic auth).
  /// Only applied for HTTP(S) sources.
  final Map<String, String> httpHeaders;

  /// Trusts any certificate for this source (self-signed WebDAV/Jellyfin servers).
  final bool allowSelfSigned;

  /// Jellyfin identifiers for the stable resume key (`jellyfin:<host>/<item>`).
  final String? jellyfinServerId;
  final String? jellyfinItemId;

  /// WebDAV server id (used to look up the saved credentials + base URL when
  /// discovering sibling sidecar subtitle files on the share).
  final String? webdavServerId;

  /// FTP/SFTP server id (same purpose as [webdavServerId], for FTP shares).
  final String? ftpServerId;

  /// Stable identifier for the resume feature, for sources whose [path]/[uri]
  /// rotate between sessions (e.g. iPad SMB per-file token URLs). Falls back to
  /// [path] then [uri] when null.
  final String? resumeKey;

  /// Sideloaded subtitle source: a URI of a paired `.srt`/`.ass` file sitting
  /// next to the video in the same folder.
  final String? subtitleUri;

  /// External subtitle tracks from media servers (e.g. Jellyfin SRT/ASS).
  final List<VideoExternalSub> externalSubtitles;

  /// Chapters from the container (MKV) or the server (Jellyfin). Empty when
  /// the source has none. Fertilized on next open for resume keys etc.
  final List<VideoChapter> chapters;

  /// The source is a server-side transcode (Jellyfin HLS fallback, DLNA
  /// `CI=1` stream) — lossy and re-encoded, so the player shows a badge.
  final bool isTranscoded;

  final Duration duration;
  final int? sizeBytes;
  final String? resolution;
  final String? videoCodec;
  final String? hdrHint;
  final String? audioCodec;
  final String? audioProfile;
  final String? audioChannels;

  HdrFormat get hdrFormat => detectHdrFormat(hdrHint);

  String get hdrLabel => hdrFormat.label;

  /// Best-effort origin of this video, derived from the source-specific
  /// [resumeKey]/[uri]/[path] identifiers:
  /// - `webdav_…` → WebDAV server
  /// - `cx:…` → CX Explorer SMB handoff (Android "Open with")
  /// - `folderbookmark:…` → iOS picked folder (Files app / NAS share)
  /// - `smb:…` → legacy in-app SMB
  /// - `jellyfin:…` → Jellyfin/Emby server
  /// - `content://` → Android "Open with"/bookmarked-tree URI
  /// - `file://` / plain path → on-device file
  /// - other http(s) URL → generic network source
  PlaybackSource? get playbackSource {
    final key = resumeKey;
    if (key != null) {
      if (key.startsWith('ftp_')) return PlaybackSource.ftp;
      if (key.startsWith('webdav_')) return PlaybackSource.webdav;
      if (key.startsWith('cx:')) return PlaybackSource.cxSmb;
      if (key.startsWith('folderbookmark:')) return PlaybackSource.filesSmb;
      if (key.startsWith('smb:') || key.startsWith('smb_')) return PlaybackSource.smb;
      if (key.startsWith('jellyfin:')) return PlaybackSource.jellyfin;
    }
    final u = uri;
    if (u != null) {
      final lower = u.toLowerCase();
      if (lower.startsWith('content://')) return PlaybackSource.files;
      if (lower.startsWith('file://')) return PlaybackSource.files;
      if (lower.startsWith('http://') || lower.startsWith('https://')) {
        return PlaybackSource.network;
      }
    }
    if (path != null && path!.isNotEmpty) return PlaybackSource.files;
    return null;
  }

  /// Returns a copy with [duration] replaced. The duration often isn't known
  /// until playback starts (e.g. WebDAV URLs), but the Continue watching card
  /// needs it to draw a progress bar.
  VideoItem withPlaybackInfo({required Duration duration}) {
    return VideoItem(
      id: id,
      title: title,
      path: path,
      uri: uri,
      resumeKey: resumeKey,
      duration: duration,
      sizeBytes: sizeBytes,
      resolution: resolution,
      videoCodec: videoCodec,
      hdrHint: hdrHint,
      audioCodec: audioCodec,
      audioProfile: audioProfile,
      audioChannels: audioChannels,
      subtitleUri: subtitleUri,
      httpHeaders: httpHeaders,
      allowSelfSigned: allowSelfSigned,
      jellyfinServerId: jellyfinServerId,
      jellyfinItemId: jellyfinItemId,
      webdavServerId: webdavServerId,
      ftpServerId: ftpServerId,
      externalSubtitles: externalSubtitles,
      chapters: chapters,
    );
  }

  /// A copy of this item with [externalSubtitles] replaced by [subs].
  /// Used by the mpv primary-engine path, which resolves the subtitles before
  /// the engine opens (mirroring the Media3 `open()` flow).
  VideoItem withExternalSubtitles(List<VideoExternalSub> subs) {
    return VideoItem(
      id: id,
      title: title,
      path: path,
      uri: uri,
      resumeKey: resumeKey,
      duration: duration,
      sizeBytes: sizeBytes,
      resolution: resolution,
      videoCodec: videoCodec,
      hdrHint: hdrHint,
      audioCodec: audioCodec,
      audioProfile: audioProfile,
      audioChannels: audioChannels,
      subtitleUri: subtitleUri,
      httpHeaders: httpHeaders,
      allowSelfSigned: allowSelfSigned,
      jellyfinServerId: jellyfinServerId,
      jellyfinItemId: jellyfinItemId,
      webdavServerId: webdavServerId,
      ftpServerId: ftpServerId,
      externalSubtitles: subs,
      chapters: chapters,
      isTranscoded: isTranscoded,
    );
  }

  String? get videoCodecLabel {
    final label = formatVideoCodec(videoCodec);
    return label == 'Unknown' ? null : label;
  }

  String? get audioCodecLabel {
    if (audioCodec == null) return null;
    final parts = <String>[formatAudioCodec(audioCodec)];
    if (audioProfile != null && audioProfile!.isNotEmpty) {
      parts.add(audioProfile!);
    }
    if (audioChannels != null && audioChannels!.isNotEmpty) {
      parts.add(audioChannels!);
    }
    return parts.join(' ');
  }

  String get durationLabel {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'uri': uri,
        'resumeKey': resumeKey,
        'durationMs': duration.inMilliseconds,
        'sizeBytes': sizeBytes,
        if (externalSubtitles.isNotEmpty)
          'externalSubtitles':
              externalSubtitles.map((s) => s.toJson()).toList(),
        if (chapters.isNotEmpty)
          'chapters': chapters.map((c) => c.toJson()).toList(),
        if (isTranscoded) 'isTranscoded': true,
      };

  factory VideoItem.fromJson(Map<String, dynamic> json) {
    final rawSubs = json['externalSubtitles'] as List?;
    final rawChapters = json['chapters'] as List?;
    return VideoItem(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      path: json['path'] as String?,
      uri: json['uri'] as String?,
      resumeKey: json['resumeKey'] as String?,
      duration:
          Duration(milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0),
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
      externalSubtitles: rawSubs != null
          ? rawSubs
              .whereType<Map<String, dynamic>>()
              .map(VideoExternalSub.fromJson)
              .toList()
          : const [],
      chapters: rawChapters != null
          ? rawChapters
              .whereType<Map<String, dynamic>>()
              .map(VideoChapter.fromJson)
              .toList()
          : const [],
      isTranscoded: json['isTranscoded'] == true,
    );
  }
}
