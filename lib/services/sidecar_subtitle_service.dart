import 'dart:async';
import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../models/video_item.dart';
import 'ftp_client.dart';
import 'smb_client.dart';
import 'webdav_client.dart';

/// Auto-discovers sidecar subtitle files for a video that lives on a
/// network share. Mirrors the local-filesystem pairing rule used by
/// `SubtitleFormats.findSiblingSubtitles` (Android) / `siblingSubtitles(for:)`
/// (iOS), but for SMB / WebDAV / FTP sources where the player can't just
/// `listFiles()` the parent directory itself.
///
/// **Priority: external sidecar → server external → embedded**.
/// The first sidecar matched is marked `isDefault = true`; the rest are
/// selectable from the player CC sheet. If no sidecar matches, the function
/// returns an empty list and the player falls back to the container's
/// embedded subtitle track (or whatever the server already sent via
/// `externalSubtitles`).
class SidecarSubtitleService {
  SidecarSubtitleService._();
  static final SidecarSubtitleService instance = SidecarSubtitleService._();

  /// Subtitle extensions the engines can decode natively. The list matches
  /// the iOS `subtitleExtensions` set in `AvPlayerView.swift` and the
  /// `SubtitleFormats.SUBTITLE_EXTENSIONS` set in `SubtitleFormats.kt`.
  static const _extensions = {
    'srt', 'ass', 'ssa', 'vtt', 'webvtt', 'ttml', 'dfxp', 'xml',
    'sub', 'smi', 'mpl2',
  };

  /// MIME type per extension. Matches `SubtitleFormats.mimeTypeFor()`.
  static const _mimeTypes = <String, String>{
    'srt': 'application/x-subrip',
    'ass': 'text/x-ssa',
    'ssa': 'text/x-ssa',
    'vtt': 'text/vtt',
    'webvtt': 'text/vtt',
    'ttml': 'application/ttml+xml',
    'dfxp': 'application/ttml+xml',
    'xml': 'application/ttml+xml',
    'sub': 'application/x-microdvd',
    'smi': 'application/x-sami',
    'mpl2': 'application/x-mpl2',
  };

  /// Looks up the sidecar subtitle files for [video], based on its source
  /// URI scheme:
  /// - `smb://<serverId>/<share>/<path>` → SMB list of the parent folder
  ///   (**Android only** - iOS SMB was retired, 2026-08).
  /// - `http(s)://<serverId>@…/<path>` or `https://…` with WebDAV headers
  ///   on the VideoItem → WebDAV PROPFIND/GET of the parent folder.
  /// - `ftp://` or `sftp://` → FTP LIST of the parent folder.
  ///
  /// Works on **Android and iOS**. Local-file sibling discovery (both
  /// platforms) already runs natively via the media source
  /// (`ExternalSubtitleTrack` in `AvPlayerView.swift` /
  /// `SubtitleFormats.findSiblingSubtitles` on Android).
  ///
  /// Best-effort: returns `[]` on any failure (network blip, auth error,
  /// listing unsupported by the server, etc.). Never throws.
  Future<List<VideoExternalSub>> find(VideoItem video) async {
    final uri = video.uri;
    // ignore: avoid_print
    print('[SidecarDBG] find: uri=$uri, webdavServerId=${video.webdavServerId}');
    if (uri == null || uri.isEmpty) return const [];
    try {
      // SMB sidecar discovery is Android-only: iOS SMB was retired (2026-08)
      // and its native channel is absent, so skip it to avoid a
      // MissingPluginException. WebDAV/FTP/SFTP discovery works on both.
      if (uri.startsWith('smb://')) {
        if (!Platform.isAndroid) return const [];
        return await _findSmb(uri);
      }
      if (uri.startsWith('http://') || uri.startsWith('https://')) {
        return await _findWebDavOrHttp(uri, video);
      }
      if (uri.startsWith('ftp://') || uri.startsWith('sftp://')) {
        return await _findFtp(uri);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[SidecarDBG] find: EXCEPTION $e');
      // Sidecar discovery is best-effort: never block playback.
    }
    return const [];
  }

  /// Nova-parity: copies every **remote** external subtitle to a local cache
  /// file and returns the list rewritten with `file://` URIs, so the engine
  /// reads sidecars locally (AVP issue #1605) instead of re-streaming the
  /// remote URL (which is fragile - auth reflows, connectivity drops,
  /// redirects). Scheme dispatch:
  ///
  /// - `http(s)://` → GET (Jellyfin DeliveryUrls / UPnP res URLs / generic).
  /// - `smb://<serverId>/<share>/<path>` → native jcifs-ng read.
  /// - `ftp://` / `sftp://` → native FTP/SFTP read.
  ///
  /// Already-local `file://` (WebDAV probe results) and unknown schemes pass
  /// through untouched. Best-effort: a failing download keeps the original
  /// remote URI (the engine falls back to streaming it) rather than dropping
  /// the track.
  Future<List<VideoExternalSub>> ensureLocal(
    VideoItem video,
    List<VideoExternalSub> subs,
  ) async {
    final out = <VideoExternalSub>[];
    for (final sub in subs) {
      final uri = sub.uri;
      if (uri.startsWith('file://') || !uri.contains('://')) {
        out.add(sub);
        continue;
      }
      String? local;
      if (uri.startsWith('smb://')) {
        local = await _smbToLocal(uri);
      } else if (uri.startsWith('ftp://') || uri.startsWith('sftp://')) {
        local = await _ftpToLocal(uri);
      } else if (uri.startsWith('http://') || uri.startsWith('https://')) {
        // Jellyfin DeliveryUrls already carry `api_key`; UPnP res URLs are
        // plain HTTP. Reuse the WebDAV native fetch (no server id → explicit
        // headers/trust) or the Dart HttpClient on non-Android.
        try {
          final bytes = await _fetch(
            url: uri,
            headers: video.httpHeaders,
            allowSelfSigned: video.allowSelfSigned,
          );
          if (bytes != null && bytes.isNotEmpty) {
            local = await _writeToCache(_filenameOf(uri), bytes);
          }
        } catch (e) {
          // ignore: avoid_print
          print('[SidecarDBG] ensureLocal http fetch failed ($uri): $e');
          // Subtitle download is best-effort: keep the remote URI and let the
          // engine stream it, rather than failing the whole video open.
        }
      }
      out.add(local == null
          ? sub
          : VideoExternalSub(
              uri: local,
              label: sub.label,
              language: sub.language,
              mimeType: sub.mimeType,
              isDefault: sub.isDefault,
            ));
    }
    return out;
  }

  Future<String?> _smbToLocal(String uri) async {
    final parsed = _parseSmbUri(uri);
    if (parsed == null) return null;
    final (serverId, share, path) = parsed;
    if (path.isEmpty) return null;
    try {
      final bytes = await SmbClient.instance.fetchBytes(serverId, share, path);
      if (bytes == null || bytes.isEmpty) return null;
      final local = await _writeToCache(_filenameOf(path), bytes);
      return local;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _ftpToLocal(String uri) async {
    final parsed = _parseFtpUri(uri);
    if (parsed == null) return null;
    final (_, serverId, path) = parsed;
    if (path.isEmpty) return null;
    try {
      // Same decode as `_findFtp`: the browser URI is percent-encoded but the
      // native `fetchBytes` wants the raw (decoded) remote path.
      final bytes = await FtpClient.instance.fetchBytes(serverId, _decodePath(path));
      if (bytes == null || bytes.isEmpty) return null;
      final local = await _writeToCache(_filenameOf(path), bytes);
      return local;
    } catch (_) {
      return null;
    }
  }

  /// Reverses the percent-encoding the FTP/SMB browsers apply when building
  /// playback URIs (they run each path segment through `Uri.encodeComponent`),
  /// so paths match the decoded names the native listers/fetchers use.
  static String _decodePath(String path) {
    try {
      return Uri.decodeComponent(path);
    } catch (_) {
      return path;
    }
  }

  /// Last path segment of a URI/path (the file name), used as the cache key.
  static String _filenameOf(String uriOrPath) {
    final idx = uriOrPath.lastIndexOf('/');
    return idx < 0 ? uriOrPath : uriOrPath.substring(idx + 1);
  }

  Future<List<VideoExternalSub>> _findSmb(String uri) async {
    // smb://<serverId>/<share>/<path> → split serverId, share, path.
    final parsed = _parseSmbUri(uri);
    if (parsed == null) return const [];
    final (serverId, share, path) = parsed;
    final dir = _parentDir(path);
    if (dir == null) return const [];
    final entries = await SmbClient.instance.listDirectoryAll(serverId, share, dir);
    return _buildSubs(
      source: entries.map((e) => (e.name, e.path)).toList(),
      videoPath: path,
      buildFullUri: (subPath) => 'smb://$serverId/$share/$subPath',
    );
  }

  /// Finds sidecar subtitles for an `http(s)`/WebDAV video the Nova way:
  /// instead of reverse-engineering a parent-folder listing (which is fragile
  /// - the WebDAV base-path / trailing-slash / auth dance commonly throws
  /// 403s), we guess each candidate "same-name" subtitle URL next to the video
  /// and probe it with an authenticated GET. The first hit is **downloaded to a
  /// local cache file** and attached as a `file://` track, so the engine reads
  /// it locally and never has to stream an authenticated subtitle over the
  /// network (mirrors Nova's `preFetchHTTPSubtitlesAndPrepareUpnpSubs` + its
  /// "copy remote subs locally" rule, AVP issue #1605).
  ///
  /// For a WebDAV video (`webdavServerId` set on the [VideoItem]) the candidate
  /// URLs sit on the same server, so they're fetched with the saved credentials
  /// + self-signed trust (never touched by Dart). For a generic `http(s)`-only
  /// source we fall back to the video's own [VideoItem.httpHeaders] /
  /// [VideoItem.allowSelfSigned].
  Future<List<VideoExternalSub>> _findWebDavOrHttp(
    String uri,
    VideoItem video,
  ) async {
    final webdavId = _webdavServerIdFor(video);
    // ignore: avoid_print
    print('[SidecarDBG] _findWebDavOrHttp: uri=$uri webdavId=$webdavId');

    // Only probe URL-sibling sidecars for a source backed by a real WebDAV
    // server directory. For a generic http(s) stream URL that isn't a WebDAV
    // identity (e.g. a Jellyfin "Open in external player" direct-play URL, or
    // a CX/SMB localhost proxy), sibling-subtitle probing is wrong and harmful:
    // rebuilding `…/<file>.<ext>` candidates against a stream/direct-play
    // endpoint issues several blocking GETs to the server *before* playback
    // even starts, hanging the player ("does not work at all"). WebDAV carries
    // the server identity so `listDirectory`-style pairing is reliable; generic
    // stream URLs have no discoverable sibling names - skip them entirely.
    if (webdavId == null || webdavId.isEmpty) {
      // ignore: avoid_print
      print('[SidecarDBG] _findWebDavOrHttp: no WebDAV identity - skipping probe');
      return const [];
    }

    String? baseUrl;
    Map<String, String> headers;
    bool allowSelfSigned;

    final servers = await WebDavClient.instance.listServers();
    final server = servers.firstWhere(
      (s) => s.id == webdavId,
      orElse: () => const WebDavServer(
        id: '',
        name: '',
        url: '',
        username: '',
        hasPassword: false,
      ),
    );
    if (server.id.isEmpty) {
      // ignore: avoid_print
      print('[SidecarDBG] _findWebDavOrHttp: server not found');
      return const [];
    }
    baseUrl = server.url.replaceAll(RegExp(r'/+$'), '');
    allowSelfSigned = server.allowSelfSigned;
    // Credentials are read natively per-fetch; passing an empty headers map
    // makes the native side build `Authorization` from the saved server.
    headers = const {};
    // ignore: avoid_print
    print('[SidecarDBG] _findWebDavOrHttp: server url=$baseUrl selfSigned=$allowSelfSigned');

    // Work from the parsed URI: `Uri.path` is decoded, so a playback URL that
    // is percent-encoded (`Test%20Video.en.mp4`) yields a clean `Test Video.en`
    // base here - and when we rebuild a candidate via `Uri.replace(path:)`
    // Dart re-encodes each `%`/space exactly once. (A naive string-level
    // swap re-encodes an already-encoded `%20` into `%2520` and misses every
    // space-named file.)
    final candidates = candidateSiblingUrls(uri);
    if (candidates.isEmpty) return const [];

    // Probe candidate siblings: <dir>/<videoBase>.<ext> for each subtitle
    // extension. Stop at the first hit (Nova-style; a matched track is enough).
    for (final (candidateUrl, subName) in candidates) {
      // ignore: avoid_print
      print('[SidecarDBG] _findWebDavOrHttp: probing $candidateUrl');
      final bytes = await _fetch(
        serverId: webdavId,
        url: candidateUrl,
        headers: headers,
        allowSelfSigned: allowSelfSigned,
      );
      if (bytes == null || bytes.isEmpty) continue;

      // ignore: avoid_print
      print('[SidecarDBG] _findWebDavOrHttp: HIT $candidateUrl (${bytes.length} bytes)');
      final localUri = await _writeToCache(subName, bytes);
      if (localUri == null) continue;
      return [
        VideoExternalSub(
          uri: localUri,
          label: _basename(subName),
          language: _languageFromName(subName),
          mimeType: _mimeTypeFor(subName),
          isDefault: true,
        ),
      ];
    }
    // ignore: avoid_print
    print('[SidecarDBG] _findWebDavOrHttp: no candidate matched');
    return const [];
  }

  /// Candidate "same-name" sidecar subtitle URLs for a video [uri], one per
  /// supported subtitle extension, in `(encodedUrl, decodedSubName)` pairs.
  ///
  /// `decodedSubName` (e.g. `Test Video.en.srt`) is used for the local cache
  /// filename + labels; `encodedUrl` is what actually gets fetched. Empty list
  /// when the URI is malformed / has no path. Pure + testable.
  @visibleForTesting
  static List<(String, String)> candidateSiblingUrls(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return const [];
    // `pathSegments` are DECODED (`Test Video.en.mp4`, not `Test%20...`), and
    // `.../`drops the leading slash. We rebuild from these decoded pieces via
    // `Uri.replace(path:)`, which percent-encodes exactly once - so an encoded
    // playback URL (`%20`) yields clean decoded names here and a single-encoded
    // fetch URL (never `%2520`).
    final segments = parsed.pathSegments;
    if (segments.isEmpty) return const [];
    final videoBase = _basename(segments.last);
    if (videoBase.isEmpty) return const [];
    final dirPath = segments.sublist(0, segments.length - 1).join('/');
    return [
      for (final ext in _extensions)
        (
          parsed
              .replace(
                path: dirPath.isEmpty ? '/$videoBase.$ext' : '/$dirPath/$videoBase.$ext',
                query: null,
                fragment: null,
              )
              .toString(),
          '$videoBase.$ext',
        ),
    ];
  }

  /// Runs a GET on [url], returning the body bytes on HTTP 200 or null.
  /// For WebDAV ([serverId] set) the native side attaches the saved
  /// credentials + TLS trust; otherwise [headers]/[allowSelfSigned] are used.
  Future<Uint8List?> _fetch({
    String? serverId,
    required String url,
    required Map<String, String> headers,
    required bool allowSelfSigned,
  }) async {
    // Authenticated GET via the native WebDAV client (both Android and iOS):
    // when [serverId] is the saved WebDAV server, credentials stay native and
    // never cross to Dart; otherwise the caller's headers / TLS policy are used
    // verbatim for generic http(s) sources (Jellyfin DeliveryUrls, UPnP res).
    return WebDavClient.instance.fetchUrl(
      serverId: serverId,
      url: url,
      headers: headers,
      allowSelfSigned: allowSelfSigned,
    );
  }

  Future<List<VideoExternalSub>> _findFtp(String uri) async {
    final parsed = _parseFtpUri(uri);
    if (parsed == null) return const [];
    final (scheme, serverId, path) = parsed;
    // The FTP browser percent-encodes each path segment when it builds the
    // playback URI (`ftp://<serverId><encoded path>`), while the native
    // `listDirectory` takes and returns **decoded** names - Nova's
    // `RawListerFactory` compares them decoded, so encode the URI path back
    // to raw before listing/pairing or a `Test Video` sidecar never matches
    // `Test%20Video`.
    final decoded = _decodePath(path);
    final dir = _parentDir(decoded);
    if (dir == null) return const [];
    // Nova-parity sidecar enumeration: the *full* parent listing (videos AND
    // subtitles) - the regular `listDirectory` filters to video extensions
    // and would strip the `.srt` so `_findFtp` never pairs it.
    final entries = await FtpClient.instance.listDirectoryAll(serverId, dir);
    return _buildSubs(
      source: entries.map((e) => (e.name, e.path)).toList(),
      videoPath: decoded,
      buildFullUri: (subPath) => '$scheme://$serverId$subPath',
    );
  }

  /// Filter [source] (name, relative-path) to ones that look like sidecar
  /// subtitles paired with the video at [videoPath]. Best match first; the
  /// first is flagged `isDefault = true`. Each entry's [buildFullUri] is
  /// used to construct the URI the engine will actually open.
  ///
  /// [videoPath] and each `source` path must be in the SAME form (both
  /// decoded, as the network sidecar discovery guarantees). A percent-encoded
  /// `Test%20Video.en.mp4` will NOT pair with a decoded `Test Video.en.srt`.
  @visibleForTesting
  List<VideoExternalSub> buildSubs({
    required List<(String name, String path)> source,
    required String videoPath,
    required String Function(String subPath) buildFullUri,
  }) {
    return _buildSubs(
      source: source,
      videoPath: videoPath,
      buildFullUri: buildFullUri,
    );
  }

  /// Inner implementation of [buildSubs] (private so the public surface stays
  /// test-friendly via [buildSubs]).
  List<VideoExternalSub> _buildSubs({
    required List<(String name, String path)> source,
    required String videoPath,
    required String Function(String subPath) buildFullUri,
  }) {
    final videoBase = _basename(videoPath).toLowerCase();
    final subEntries = source
        .where((e) => _isSubtitle(e.$1))
        .toList(growable: false);
    if (subEntries.isEmpty) return const [];

    // Pass 1: exact base or base-with-extra-tokens match (preferred).
    final preferred = <(String name, String path, int score)>[];
    for (final e in subEntries) {
      final subBase = _basename(e.$1).toLowerCase();
      var score = 0;
      if (subBase == videoBase) {
        score = 200;
      } else if (subBase.startsWith('$videoBase.')) {
        score = 100;
      } else if (videoBase.startsWith('$subBase.')) {
        score = 80; // sub is a less-specific prefix of the video name
      } else {
        continue;
      }
      preferred.add((e.$1, e.$2, score));
    }
    preferred.sort((a, b) {
      final s = b.$3.compareTo(a.$3);
      return s != 0 ? s : a.$1.compareTo(b.$1);
    });

    if (preferred.isEmpty) return const [];

    // Cap to 8 matches - anything beyond is noise (a folder full of dub tracks
    // makes the CC sheet unreadable).
    final chosen = preferred.length > 8 ? preferred.sublist(0, 8) : preferred;

    return [
      for (var i = 0; i < chosen.length; i++)
        VideoExternalSub(
          uri: buildFullUri(chosen[i].$2),
          label: _basename(chosen[i].$1),
          language: _languageFromName(chosen[i].$1),
          mimeType: _mimeTypeFor(chosen[i].$1),
          isDefault: i == 0,
        ),
    ];
  }

  // ---------- URI parsing ----------

  /// smb://{serverId}/{share}/{dir}/{file}
  (String, String, String)? _parseSmbUri(String uri) {
    // Strip scheme.
    var rest = uri.substring('smb://'.length);
    // First segment = serverId, no '/' inside (it's a UUID / nanoid).
    final firstSlash = rest.indexOf('/');
    if (firstSlash < 0) return null;
    final serverId = rest.substring(0, firstSlash);
    rest = rest.substring(firstSlash + 1);
    // Second segment = share, may contain no '/'.
    final secondSlash = rest.indexOf('/');
    final share = secondSlash < 0 ? rest : rest.substring(0, secondSlash);
    final path = secondSlash < 0 ? '' : rest.substring(secondSlash + 1);
    if (serverId.isEmpty || share.isEmpty) return null;
    return (serverId, share, path);
  }

  /// Parses `ftp://<serverId><path>` / `sftp://<serverId><path>` (no `@`).
  /// The native FtpDataSource identifies the saved server by the first path
  /// segment after the scheme (everything up to the first `/`).
  (String, String, String)? _parseFtpUri(String uri) {
    final lower = uri.toLowerCase();
    final schemeEnd = lower.indexOf('://');
    if (schemeEnd < 0) return null;
    final scheme = lower.substring(0, schemeEnd); // 'ftp' or 'sftp'
    final rest = uri.substring(schemeEnd + 3);
    final firstSlash = rest.indexOf('/');
    final serverId = firstSlash < 0 ? rest : rest.substring(0, firstSlash);
    final path = firstSlash < 0 ? '' : rest.substring(firstSlash + 1);
    if (serverId.isEmpty) return null;
    return (scheme, serverId, path);
  }

  /// Pulls the WebDAV serverId off the VideoItem. We don't store it on
  /// `VideoItem` directly today, so fall back to a private hook in the
  /// `exo_player.dart` open path. For now, this returns null and the
  /// discovery is skipped on WebDAV - the WebDAV browser screens already
  /// pre-populate `externalSubtitles` from their own listings.
  String? _webdavServerIdFor(VideoItem video) {
    return video.webdavServerId;
  }

  // ---------- path helpers ----------

  /// The path portion of a URL (e.g. `http://host:8080/dav` → `/dav`,
  /// `http://host` → ''). The leading slash is preserved so callers can match
  /// a URL path that includes it; empty when the URL has no path.
  @visibleForTesting
  static String urlBasePath(String url) {
    final schemeEnd = url.indexOf('://');
    if (schemeEnd < 0) return '';
    final rest = url.substring(schemeEnd + 3);
    final slash = rest.indexOf('/');
    if (slash < 0) return '';
    final path = rest.substring(slash);
    return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }

  /// Strips a server base path (from `urlBasePath`, i.e. `/dav`) off a
  /// slash-less URL path (as `_parseHttpUri` produces, i.e. `dav/Movies/...`),
  /// returning the remainder `Movies/...`. Returns the input unchanged when the
  /// base path is empty or doesn't prefix the URL path; returns `''` when the
  /// URL path *is* the base path. Handles the one-side-has-slash normalization.
  @visibleForTesting
  static String relativeToBasePath(String basePath, String urlPath) {
    var base = basePath;
    var path = urlPath;
    // Compare without a leading slash on either side (basePath is `/dav`,
    // urlPath is `dav/...`).
    if (base.startsWith('/')) base = base.substring(1);
    if (path.startsWith('/')) path = path.substring(1);
    if (base.isEmpty) return urlPath;
    if (path == base) return '';
    if (path.startsWith('$base/')) return path.substring(base.length + 1);
    return urlPath;
  }

  /// Parent directory of a posix-style path. Returns null for top-level files.
  String? _parentDir(String path) {
    if (path.isEmpty) return null;
    final idx = path.lastIndexOf('/');
    if (idx < 0) return null; // no parent (e.g. `file.mkv`)
    return path.substring(0, idx);
  }

  /// Percent-encodes a single URL path segment (preserves nothing but
  /// alphanumerics + `-._~`), so names with spaces/`+`/brackets round-trip.
  String _encodeSegment(String segment) => Uri.encodeComponent(segment);

  /// Writes a downloaded subtitle to a per-name local cache file and returns
  /// its `file://` URI (or null on failure). Keyed by the subtitle basename so
  /// re-opens reuse the same file; the cache dir is recreated lazily.
  Future<String?> _writeToCache(String name, Uint8List bytes) async {
    try {
      final base = await _cacheDir();
      final safe = _encodeSegment(name);
      final file = File('${base.path}/$safe');
      await file.writeAsBytes(bytes, flush: true);
      return file.uri.toString();
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _cacheDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/sidecar_subs');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// File name without the last extension. `Show.S01E01.eng.srt` → `Show.S01E01.eng`.
  static String _basename(String pathOrName) {
    final name = pathOrName.contains('/')
        ? pathOrName.substring(pathOrName.lastIndexOf('/') + 1)
        : pathOrName;
    final dot = name.lastIndexOf('.');
    if (dot < 0) return name;
    return name.substring(0, dot);
  }

  /// True if the file name has a subtitle extension we understand.
  bool _isSubtitle(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    return _extensions.contains(ext);
  }

  /// MIME type for the given file name, falling back to SRT (the most
  /// common format).
  String _mimeTypeFor(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    return _mimeTypes[ext] ?? 'application/x-subrip';
  }

  /// 2..6-char language tag between the last two dots: `Show.S01E01.eng.srt`
  /// → `eng`. Mirrors `SubtitleFormats.languageFromFileName`.
  String _languageFromName(String name) {
    final lower = name.toLowerCase();
    final last = lower.lastIndexOf('.');
    if (last <= 0) return '';
    var prev = -1;
    for (var i = last - 1; i >= 0; i--) {
      if (lower[i] == '.') {
        prev = i;
        break;
      }
    }
    if (prev < 0) return '';
    final len = last - prev - 1;
    if (len < 2 || len > 6) return '';
    return lower.substring(prev + 1, last);
  }
}
