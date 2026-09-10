import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';
import '../models/video_item.dart';
import '../services/file_browser.dart';
import '../services/ftp_client.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/resume_progress_helper.dart';
import '../services/smb_client.dart';
import '../services/simkl_client.dart';
import '../services/tmdb_client.dart';
import '../services/upnp_client.dart';
import '../services/watched_store.dart';
import '../services/webdav_client.dart';
import '../utils/file_info_extractor.dart';
import '../utils/season_group.dart' as sg;
import '../widgets/season_progress_ring.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/tv_tile.dart';
import 'tmd_details_screen.dart';

/// The contents of a library folder. For a TV-show folder this is the episode
/// list; subfolders navigate one level at a time. Videos open their TMDB
/// details page (Play/Resume) instead of playing directly. Home routes folder
/// taps to `TmdDetailsScreen(folder:)`; this screen is used for subfolder
/// navigation once you're inside. Jellyfin library folders list their children
/// through the server API instead of the file browser.
class FolderScreen extends StatefulWidget {
  const FolderScreen({super.key, required this.folder, this.initialPath});

  final LibraryFolder folder;

  /// Start browsing at this subfolder instead of the folder root (deep links
  /// from the details screen's episode list).
  final String? initialPath;

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> {
  static final FileBrowserService _service = FileBrowserService.instance;
  final JellyfinClient _jellyfin = JellyfinClient();

  late String _currentPath;
  List<FileEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  /// Watched marks for the current list, keyed by each row's stable resume
  /// key (same keys the player auto-marks on completion).
  Set<String> _watchedKeys = {};

  /// Resume positions (ms) per entry, keyed by the same resume key used for
  /// watched marks.  Populated on folder load so episode tiles can show a
  /// progress bar without an async lookup per tile.
  Map<String, int> _resumePositionsMs = {};

  /// Total duration (ms) per entry from the continue-watching store, keyed by
  /// the same resume key.  Combined with [_resumePositionsMs] to draw a
  /// proper progress bar for any file (episodes AND standalone videos).
  Map<String, int> _durationsMs = {};

  /// SIMKL cloud-done backfill (mirrors smb_screen.dart's sync button).
  bool _syncingSimkl = false;

  bool get _enableSimklSync =>
      (widget.folder.isJellyfin || widget.folder.isNetwork) &&
      _currentEntries.isNotEmpty &&
      !_isSeriesFolder;

  /// Series folder detection (same logic as SMB screen).
  bool _isSeriesFolder = false;
  TmdMeta? _seriesMeta;
  TmdDetails? _seriesDetails;

  /// Generation counter to prevent stale async `_detectAndLoadSeriesFolder`
  /// calls from overwriting `_seriesMeta` when a newer load is in flight.
  int _seriesGeneration = 0;
  bool _loadingSeriesMeta = false;
  final Set<int> _expandedSeasons = {};

  /// Jellyfin mode: the folder crumbs (name + item id) below the root, the
  /// resolved server, and the current level's children.
  List<({String name, String id})> _jellyfinCrumbs = const [];
  JellyfinServer? _jellyfinServer;
  List<JellyfinItem> _jellyfinEntries = const [];

  /// Network modes
  List<SmbEntry> _smbEntries = const [];
  // WebDAV entries reuse simple maps; keep as dynamic for now.
  List<Object> _networkEntries = const [];
  List<FtpEntry> _ftpEntries = const [];
  List<UpnpEntry> _upnpEntries = const [];

  /// UPnP mode: the container crumbs (object id + name) below the root so
  /// object-id-based navigation can go back up. Root = empty crumbs.
  List<({String id, String name})> _upnpCrumbs = const [];

  /// FTP mode: the bookmarked server is an SFTP server (scheme for playback
  /// URIs). Looked up once on open from the saved servers.
  bool _ftpIsSftp = false;
  bool _ftpIsSftpResolved = false;

  /// Background-fetched SMB file sizes (path → bytes).
  final Map<String, int> _smbFileSizes = {};

  bool get _atRoot {
    if (_isJellyfin) return _jellyfinCrumbs.isEmpty;
    if (_isUpnp) return _upnpCrumbs.isEmpty;
    if (_isSmb || _isWebDav || _isFtp) return _currentPath == _networkPath;
    return _currentPath == widget.folder.path;
  }

  bool get _isJellyfin => widget.folder.isJellyfin;
  bool get _isSmb => widget.folder.source == LibraryFolderSource.smb;
  bool get _isWebDav => widget.folder.source == LibraryFolderSource.webdav;
  bool get _isFtp => widget.folder.source == LibraryFolderSource.ftp;
  bool get _isUpnp => widget.folder.source == LibraryFolderSource.upnp;
  bool get _isNetworkFolder => widget.folder.isNetwork && !_isJellyfin;

  // Network folder navigation state (SMB/WebDAV share + subpath).
  late String _networkShare;
  late String _networkPath;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath ?? widget.folder.path;
    _networkShare = widget.folder.networkShare ?? '';
    _networkPath = widget.folder.networkPath ?? '';
    // For network folders, _currentPath tracks the subpath under the share.
    if (_isNetworkFolder && widget.initialPath == null) {
      _currentPath = _networkPath;
    }
    TmdService.instance.addListener(_onMetadataChanged);
    _resolveMeta();
    _load();
  }

  @override
  void dispose() {
    TmdService.instance.removeListener(_onMetadataChanged);
    super.dispose();
  }

  void _onMetadataChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _resolveMeta() async {
    try {
      await TmdService.instance.resolveFolder(
        widget.folder.metadataKey,
        widget.folder.name,
        yearHint: widget.folder.yearHint,
      );
    } catch (_) {
      // Non-fatal: the header just stays a placeholder.
    }
  }

  Future<void> _load() async {
    // Pre-populate series state from cache for the CURRENT subfolder path so
    // there's no stale-view flash when navigating between subfolders.  At root
    // level, always start with _isSeriesFolder = false — root folders with
    // subfolders are never series folders, and _detectAndLoadSeriesFolder will
    // set the correct state once it knows whether subfolders exist.
    final service = TmdService.instance;
    final folderName = _subfolderName;
    final metadataKey = _atRoot
        ? widget.folder.metadataKey
        : '${widget.folder.metadataKey}/$folderName';
    final cachedSeriesMeta = service.metaFor(metadataKey);
    final hasCachedSeries = !_atRoot &&
        cachedSeriesMeta != null &&
        cachedSeriesMeta.folderSeason != null;
    setState(() {
      _loading = true;
      _error = null;
      _expandedSeasons.clear();
      if (hasCachedSeries) {
        _isSeriesFolder = true;
        _seriesMeta = cachedSeriesMeta;
        _seriesDetails = cachedSeriesMeta.details;
        _loadingSeriesMeta = false;
      } else {
        _isSeriesFolder = false;
        _seriesMeta = null;
        _seriesDetails = null;
        _loadingSeriesMeta = false;
      }
    });
    if (_isJellyfin) {
      await _loadJellyfin();
      return;
    }
    if (_isSmb) {
      await _loadSmb();
      return;
    }
    if (_isWebDav) {
      await _loadWebDav();
      return;
    }
    if (_isFtp) {
      await _loadFtp();
      return;
    }
    if (_isUpnp) {
      await _loadUpnp();
      return;
    }
    try {
      final entries = await _service.listDirectory(_currentPath);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
      await _refreshWatched();
      // Nova-style: background-resolve TMDB for all video files so metadata
      // is ready when the user taps a file.
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        TmdService.instance.resolve(_toVideoItem(entry)).catchError((_) {
          return null;
        });
      }
      _detectAndLoadSeriesFolder();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'Could not list this folder';
        _loading = false;
      });
    }
  }

  /// Detects whether the current folder is a TV series folder (≥1 files with
  /// SxxExx patterns or sequential numbering) and fetches TMDB metadata for
  /// the series header.
  Future<void> _detectAndLoadSeriesFolder() async {
    final entries = _currentEntries;
    if (entries.isEmpty) return;

    final gen = ++_seriesGeneration;

    // Count subfolders vs video files.
    final hasSubfolders = entries.any(_isFolderEntry);
    final videoNames = <String>[];
    for (final e in entries) {
      if (_isFolderEntry(e)) continue;
      videoNames.add(_nameOf(e));
    }
    // Folder contains only subfolders (no direct video files) — check if they
    // look like season folders and fetch TMDB metadata for the poster grid.
    if (hasSubfolders && videoNames.isEmpty) {
      // Folder contains only subfolders — check if they look like seasons.
      final folderSeasons = <int>{};
      for (final e in entries) {
        if (!_isFolderEntry(e)) continue;
        final s = _parseSeasonFromFolderName(_nameOf(e));
        if (s != null && s > 0) folderSeasons.add(s);
      }
      if (folderSeasons.isEmpty) {
        // Subfolders don't look like seasons — stay in flat list.
        if (_isSeriesFolder) setState(() => _isSeriesFolder = false);
        return;
      }
      // Season subfolders detected — fetch TMDB metadata for poster grid.
      final folderName = _subfolderName;
      final metadataKey = _atRoot
          ? widget.folder.metadataKey
          : '${widget.folder.metadataKey}/$folderName';
      setState(() {
        _loadingSeriesMeta = true;
      });
      final service = TmdService.instance;
      await service.ensureLoaded();
      var meta = service.metaFor(metadataKey);
      if (meta == null || meta.folderSeason == null) {
        meta = await service.resolveFolder(
          metadataKey,
          folderName,
          yearHint: ParsedFileName.yearFromNames([]),
        );
      }
      if (!mounted || gen != _seriesGeneration) return;
      if (meta != null) {
        final details = await service.detailsFor(metadataKey);
        if (!mounted || gen != _seriesGeneration) return;
        // Fetch season data for each detected season folder.
        for (final s in folderSeasons) {
          await service.seasonFor(metadataKey, s);
          if (!mounted) return;
        }
        final freshMeta = service.metaFor(metadataKey) ?? meta;
        setState(() {
          _seriesMeta = freshMeta;
          _seriesDetails = details;
          _loadingSeriesMeta = false;
        });
      } else {
        setState(() {
          _loadingSeriesMeta = false;
        });
      }
      return;
    }

    // Bail: no video files and no season-subfolder match.
    if (videoNames.isEmpty) {
      if (_isSeriesFolder) setState(() => _isSeriesFolder = false);
      return;
    }

    // Mixed subfolders + video files → detect seasons and show grid + episodes.
    if (hasSubfolders) {
      // Check if any subfolders look like seasons.
      final folderSeasons = <int>{};
      for (final e in entries) {
        if (!_isFolderEntry(e)) continue;
        final s = _parseSeasonFromFolderName(_nameOf(e));
        if (s != null && s > 0) folderSeasons.add(s);
      }
      if (folderSeasons.isEmpty) {
        // Subfolders don't look like seasons — stay in flat list.
        if (_isSeriesFolder) setState(() => _isSeriesFolder = false);
        return;
      }
      // Season subfolders detected — set series mode and fall through to
      // the normal series-folder path below.
      setState(() {
        _isSeriesFolder = true;
      });
    }

    // Series detected — fetch TMDB metadata for the current folder, not
    // the root bookmark. When navigating into a subfolder, use its name.
    final folderName = _subfolderName;
    final metadataKey = _atRoot
        ? widget.folder.metadataKey
        : '${widget.folder.metadataKey}/$folderName';

    // Check for SxxExx episode patterns.
    final episodeNames =
        videoNames.where((n) => ParsedFileName.parse(n).isEpisode).toList();

    // Fallback: sequential numbering detection.
    final hasSequential = episodeNames.isEmpty && _hasSequentialNumbering(videoNames);

    setState(() {
      _isSeriesFolder = true;
    });

    final service = TmdService.instance;
    await service.ensureLoaded();

    var meta = service.metaFor(metadataKey);
    if (meta != null && meta.folderSeason != null) {
      // Cache hit with season data — use it directly.
    } else {
      setState(() => _loadingSeriesMeta = true);
      meta = await service.resolveFolder(
        metadataKey,
        folderName,
        yearHint: ParsedFileName.yearFromNames(videoNames),
      );
    }

    if (!mounted || gen != _seriesGeneration) return;
    if (meta == null) {
      setState(() {
        _seriesMeta = null;
        _seriesDetails = null;
        _loadingSeriesMeta = false;
      });
      return;
    }

    final details = await service.detailsFor(metadataKey);
    if (!mounted || gen != _seriesGeneration) return;

    setState(() {
      _seriesMeta = meta;
      _seriesDetails = details;
      _loadingSeriesMeta = false;
    });

    // Fetch season data for locally-present seasons.
    final seasonsNeeded = <int>{};
    for (final n in episodeNames) {
      final s = ParsedFileName.parse(n).season;
      if (s > 0) seasonsNeeded.add(s);
    }
    // When folderSeason is set (from TMDB season-name matching), always
    // fetch that season's data even if parsed seasons are all 0 (anime [01]).
    if (meta.folderSeason != null) seasonsNeeded.add(meta.folderSeason!);
    if (seasonsNeeded.isEmpty && hasSequential) seasonsNeeded.add(1);
    // Anime bracket numbering ([01]/[02]) — parsed seasons are all 0 and
    // folderSeason may be null. Always fetch season 1 so episode stills
    // resolve to the first (only) season on TMDB.
    if (seasonsNeeded.isEmpty && episodeNames.isNotEmpty) {
      seasonsNeeded.add(1);
    }
    for (final season in seasonsNeeded) {
      await service.seasonFor(metadataKey, season);
      if (!mounted) return;
    }
    if (!mounted || gen != _seriesGeneration) return;
    // Read the latest meta from the cache (each seasonFor replaces it with a
    // new TmdMeta; the `meta` reference we held earlier is stale). Without
    // this, _episodeFor looks up an empty seasons map and per-episode
    // details (stills/names/ratings/overview) never appear until the user
    // backs out and re-enters — the cache hit on re-entry uses the fresh
    // meta and the UI populates.
    final freshMeta = service.metaFor(metadataKey) ?? meta;
    setState(() {
      _seriesMeta = freshMeta;
    });
  }

  /// Parse a season number from a subfolder name (e.g. "House S02 1080p" → 2).
  static int? _parseSeasonFromFolderName(String name) {
    final parsed = ParsedFileName.parse(name);
    if (parsed.season > 0) return parsed.season;
    final sMatch =
        RegExp(r'\bS(\d{1,2})\b', caseSensitive: false).firstMatch(name);
    if (sMatch != null) return int.tryParse(sMatch.group(1)!);
    final seasonMatch =
        RegExp(r'\bSeason\s+(\d{1,2})\b', caseSensitive: false)
            .firstMatch(name);
    if (seasonMatch != null) return int.tryParse(seasonMatch.group(1)!);
    return null;
  }

  /// Checks whether file names have sequential numbering (e.g. `- 01.mkv`,
  /// `E01.1080p`, `- 02.mkv`). Returns true if ≥2 files have numbers forming
  /// a near-continuous sequence starting from 1.
  static bool _hasSequentialNumbering(List<String> names) {
    if (names.length < 2) return false;

    // Pattern 1: E01 / EP01 / E1 / EP1 style (most common for anime/TV rips)
    final epPattern = RegExp(r'\bE(?:P)?(\d{1,3})\b', caseSensitive: false);
    // Pattern 2: Standalone number (01, 02, 1, 2) — must NOT be preceded by
    // a letter (avoids matching codec tags like x265, h264) and must NOT be
    // followed by a letter (avoids matching res like 1080p).
    final numPattern = RegExp(r'(?<![a-zA-Z])(\d{1,3})(?![a-zA-Z])');

    final numbers = <int>[];
    for (final name in names) {
      // Try E01/EP01 pattern first — highest confidence.
      final epMatch = epPattern.firstMatch(name);
      if (epMatch != null) {
        final n = int.tryParse(epMatch.group(1)!);
        if (n != null && n >= 1 && n <= 999) {
          numbers.add(n);
          continue;
        }
      }
      // Fallback: standalone number anywhere in the name.
      int? best;
      for (final m in numPattern.allMatches(name)) {
        final n = int.tryParse(m.group(1)!);
        if (n != null && n >= 1 && n <= 200) {
          // Skip common noise: year (19xx/20xx), resolution (480/720/1080/2160),
          // bitrate (128/256/320/640), codec (264/265/655).
          if (n >= 1900 || n == 480 || n == 720 || n == 1080 || n == 2160 ||
              n == 128 || n == 256 || n == 320 || n == 640 ||
              n == 264 || n == 265 || n == 655) {
            continue;
          }
          best = n;
          break; // Take the first valid number.
        }
      }
      if (best != null) numbers.add(best);
    }

    if (numbers.length < 2) return false;
    numbers.sort();
    if (numbers.first > 1) return false;
    var consecutive = 0;
    var expected = numbers.first;
    for (final n in numbers) {
      if (n == expected || n == expected + 1) {
        consecutive++;
        expected = n + 1;
      }
    }
    return consecutive >= (names.length + 1) ~/ 2;
  }

  Future<void> _loadJellyfin() async {
    try {
      final server =
          await _jellyfin.serverForUrl(widget.folder.jellyfinServerUrl ?? '');
      if (server == null || !server.isAuthenticated) {
        throw const JellyfinException(
          'Jellyfin server is not signed in — open the Jellyfin screen and '
          'sign in first.',
        );
      }
      final parentId = _jellyfinCrumbs.isEmpty
          ? (widget.folder.jellyfinItemId ?? '')
          : _jellyfinCrumbs.last.id;
      final items = await _jellyfin.getItems(server, parentId);
      if (!mounted) return;
      final folders = items.where((i) => i.isFolder).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final playables = items.where((i) => i.isPlayable).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _jellyfinServer = server;
        _jellyfinEntries = [...folders, ...playables];
        _loading = false;
      });
      await _refreshWatched();
      _detectAndLoadSeriesFolder();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is JellyfinException
            ? e.message
            : JellyfinClient.friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<void> _loadSmb() async {
    try {
      final serverId = widget.folder.networkServerId ?? '';
      final share = widget.folder.networkShare ?? _networkShare;
      final path = _currentPath.replaceAll(RegExp(r'/+$'), '').replaceAll(RegExp(r'^/+'), '');
      final entries = await SmbClient.instance.listDirectory(serverId, share, path);
      if (!mounted) return;

      // Pre-populate ALL cached data in ONE setState.
      final service = TmdService.instance;
      final cleanPath = path.replaceAll(RegExp(r'/+$'), '');
      final folderName = cleanPath.split('/').lastOrNull ?? widget.folder.name;
      final metadataKey = cleanPath.isEmpty || cleanPath == widget.folder.path
          ? widget.folder.metadataKey
          : '${widget.folder.metadataKey}/$folderName';
      final cachedSeriesMeta = service.metaFor(metadataKey);
      final isCachedSeries = cachedSeriesMeta != null &&
          cachedSeriesMeta.folderSeason != null &&
          cachedSeriesMeta.details != null;
      final cachedSeasonsReady = isCachedSeries &&
          cachedSeriesMeta.seasons.isNotEmpty;

      setState(() {
        _smbEntries = entries;
        _loading = false;
        _smbFileSizes.clear();
        if (isCachedSeries) {
          _isSeriesFolder = true;
          _seriesMeta = cachedSeriesMeta;
          _seriesDetails = cachedSeriesMeta.details;
          _loadingSeriesMeta = false;
        }
      });
      await _refreshWatched();

      // Only prefetch uncached entries.
      for (final e in entries) {
        if (e.isDirectory) continue;
        final key = 'smb:$serverId/$share/${e.path}';
        if (service.metaFor(key) != null) continue;
        service.resolve(_toVideoItem(e)).catchError((_) => null);
      }
      if (!cachedSeasonsReady) {
        _detectAndLoadSeriesFolder();
      }
      _fetchSmbSizes(entries);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'Could not list this folder';
        _loading = false;
      });
    }
  }

  /// Background-fetch SMB file sizes. listDirectory returns 0 for performance.
  void _fetchSmbSizes(List<SmbEntry> entries) {
    final serverId = widget.folder.networkServerId;
    final share = widget.folder.networkShare ?? _networkShare;
    if (serverId == null || share.isEmpty) return;
    final paths = entries
        .where((e) => !e.isDirectory && e.size <= 0)
        .map((e) => e.path)
        .toList();
    if (paths.isEmpty) return;
    SmbClient.instance.fetchSizes(serverId, share, paths).then((sizes) {
      if (!mounted || sizes.isEmpty) return;
      setState(() => _smbFileSizes.addAll(sizes));
    });
  }

  Future<void> _loadWebDav() async {
    try {
      final serverId = widget.folder.networkServerId ?? '';
      final basePath = widget.folder.networkPath ?? '';
      final path = _currentPath.isEmpty ? basePath : _currentPath;
      final entries = await WebDavClient.instance.listDirectory(serverId, path);
      if (!mounted) return;
      setState(() {
        _networkEntries = entries;
        _loading = false;
      });
      await _refreshWatched();
      for (final e in entries) {
        if (e.isDirectory) continue;
        TmdService.instance.resolve(_toVideoItem(e)).catchError((_) => null);
      }
      _detectAndLoadSeriesFolder();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'Could not list this folder';
        _loading = false;
      });
    }
  }

  Future<void> _loadFtp() async {
    try {
      if (!_ftpIsSftpResolved) {
        // Look up the saved server once so playback URIs pick ftp:// vs
        // sftp:// (the FTP channel is iOS-only; on Android it's missing).
        try {
          final servers = await FtpClient.instance.listServers();
          if (mounted) {
            _ftpIsSftp = servers.any((s) =>
                s.id == widget.folder.networkServerId && s.isSftp);
          }
        } catch (_) {}
        _ftpIsSftpResolved = true;
      }
      final serverId = widget.folder.networkServerId ?? '';
      final basePath = widget.folder.networkPath ?? '';
      final path = _currentPath.isEmpty ? basePath : _currentPath;
      final entries = await FtpClient.instance.listDirectory(serverId, path);
      if (!mounted) return;
      setState(() {
        _ftpEntries = entries;
        _loading = false;
      });
      await _refreshWatched();
      for (final e in entries) {
        if (e.isDirectory) continue;
        TmdService.instance.resolve(_toVideoItem(e)).catchError((_) => null);
      }
      _detectAndLoadSeriesFolder();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is PlatformException
            ? (e.message ?? 'Could not list this folder')
            : 'Could not list this folder';
        _loading = false;
      });
    }
  }

  Future<void> _loadUpnp() async {
    try {
      final serverId = widget.folder.networkServerId ?? '';
      // Root container: the bookmarked object id is the root's own id.
      final objectId = _upnpCrumbs.isEmpty
          ? (widget.folder.networkPath ?? '0')
          : _upnpCrumbs.last.id;
      final entries = await UpnpClient.instance.browse(serverId, objectId);
      if (!mounted) return;
      setState(() {
        _upnpEntries = entries;
        _loading = false;
      });
      await _refreshWatched();
      for (final e in entries) {
        if (e.isDirectory) continue;
        TmdService.instance.resolve(_toVideoItem(e)).catchError((_) => null);
      }
      _detectAndLoadSeriesFolder();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is PlatformException
            ? (e.message ?? 'Could not list this folder')
            : 'Could not list this folder';
        _loading = false;
      });
    }
  }

  Future<void> _openWebDavEntry(WebDavEntry entry) async {
    if (entry.isDirectory) {
      FocusScope.of(context).unfocus();
      setState(() {
        _currentPath = entry.path.replaceAll('//', '/').replaceAll(RegExp(r'/+$'), '');
        _loading = true;
      });
      await _loadWebDav();
      return;
    }
    final video = _toVideoItem(entry);
    final folderName = _subfolderName;
    final folderKey = _atRoot
        ? widget.folder.metadataKey
        : '${widget.folder.metadataKey}/$folderName';
    final folderMeta = TmdService.instance.metaFor(folderKey);
    final parsed = ParsedFileName.parse(entry.name);
    final isEp = parsed.isEpisode || _epPattern.hasMatch(entry.name);
    String? parentKey;
    if (isEp && folderMeta != null && folderMeta.movie.kind == TmdKind.tv) {
      parentKey = folderKey;
      try { await TmdService.instance.carryMeta(folderKey, TmdStore.identityKeyFor(video)); } catch (_) {}
    } else if (!isEp && folderMeta != null) {
      final videoKey = TmdStore.identityKeyFor(video);
      final existing = TmdService.instance.metaFor(videoKey);
      if (existing != null && existing.movie.id == folderMeta.movie.id) {
        try { await TmdService.instance.clear(videoKey); } catch (_) {}
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: video,
          parentMetadataKey: parentKey,
        ),
      ),
    );
    await _loadWebDav();
  }


  Future<void> _openEntry(FileEntry entry) async {
    if (entry.isDirectory) {
      FocusScope.of(context).unfocus();
      setState(() => _currentPath = entry.path.replaceAll('//', '/').replaceAll(RegExp(r'/+$'), ''));
      await _load();
      return;
    }
    final video = _toVideoItem(entry);
    // Use the subfolder-aware metadataKey so episodes in subfolders
    // (e.g. "Strike the Blood Final") resolve to the correct season.
    final folderName = _subfolderName;
    final folderKey = _atRoot
        ? widget.folder.metadataKey
        : '${widget.folder.metadataKey}/$folderName';
    final folderMeta = TmdService.instance.metaFor(folderKey);
    final parsed = ParsedFileName.parse(entry.name);
    final isEp = parsed.isEpisode || _epPattern.hasMatch(entry.name);
    String? parentKey;
    if (isEp && folderMeta != null && folderMeta.movie.kind == TmdKind.tv) {
      parentKey = folderKey;
      try {
        await TmdService.instance.carryMeta(folderKey, TmdStore.identityKeyFor(video));
      } catch (_) {}
    } else if (!isEp && folderMeta != null) {
      final videoKey = TmdStore.identityKeyFor(video);
      final existing = TmdService.instance.metaFor(videoKey);
      if (existing != null && existing.movie.id == folderMeta.movie.id) {
        try { await TmdService.instance.clear(videoKey); } catch (_) {}
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: video,
          parentMetadataKey: parentKey,
        ),
      ),
    );
    // Resume positions may have changed while playing.
    await _load();
  }

  Future<void> _openJellyfinItem(JellyfinItem item) async {
    final server = _jellyfinServer;
    if (server == null) return;
    if (item.isFolder) {
      setState(() {
        _jellyfinCrumbs = [..._jellyfinCrumbs, (name: item.name, id: item.id)];
        _loading = true;
      });
      await _loadJellyfin();
      return;
    }
    if (!item.isPlayable) return;
    final video = _jellyfin.videoItem(server, item);
    final folderKey = widget.folder.metadataKey;
    final folderMeta = TmdService.instance.metaFor(folderKey);
    final isEp = item.type == 'Episode' ||
        (item.parentIndexNumber != null && item.indexNumber != null);
    String? parentKey;
    if (isEp && folderMeta != null && folderMeta.movie.kind == TmdKind.tv) {
      parentKey = folderKey;
      try { await TmdService.instance.carryMeta(folderKey, TmdStore.identityKeyFor(video)); } catch (_) {}
    } else if (!isEp && folderMeta != null) {
      final videoKey = TmdStore.identityKeyFor(video);
      final existing = TmdService.instance.metaFor(videoKey);
      if (existing != null && existing.movie.id == folderMeta.movie.id) {
        try { await TmdService.instance.clear(videoKey); } catch (_) {}
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: video,
          parentMetadataKey: parentKey,
        ),
      ),
    );
    // Resume positions may have changed while playing.
    await _loadJellyfin();
  }

  Future<void> _openSmbEntry(SmbEntry entry) async {
    if (entry.isDirectory) {
      FocusScope.of(context).unfocus();
      setState(() {
        _currentPath = entry.path.replaceAll('//', '/').replaceAll(RegExp(r'/+$'), '');
        _loading = true;
      });
      await _loadSmb();
      return;
    }
    final serverId = widget.folder.networkServerId ?? '';
    final share = widget.folder.networkShare ?? _networkShare;
    final uri = await SmbClient.instance.openShare(serverId, share, entry.path);
    final resumeKey = 'smb:$serverId/$share/${entry.path}';
    final fi = extractFileInfo(entry.name);
    final item = VideoItem(
      id: 'smb_${widget.folder.id}_${entry.path.hashCode}',
      title: entry.name,
      path: 'smb://$share/${entry.path}',
      uri: uri,
      resumeKey: resumeKey,
      duration: Duration.zero,
      sizeBytes: entry.size,
      videoCodec: fi.videoCodec,
      audioCodec: fi.audioCodec,
      audioChannels: fi.audioChannels,
      audioLanguage: fi.audioLanguage,
      resolution: fi.resolution,
      fps: fi.fps,
      hdrHint: fi.hdrHint,
    );
    if (!mounted) return;
    // Use the subfolder-aware metadataKey so episodes in subfolders
    // (e.g. "Strike the Blood Final") resolve to the correct season.
    final smbFolderName = _subfolderName;
    final folderKey = _atRoot
        ? widget.folder.metadataKey
        : '${widget.folder.metadataKey}/$smbFolderName';
    final folderMeta = TmdService.instance.metaFor(folderKey);
    final parsed = ParsedFileName.parse(entry.name);
    final isEp = parsed.isEpisode || _epPattern.hasMatch(entry.name);
    String? parentKey;
    if (isEp && folderMeta != null && folderMeta.movie.kind == TmdKind.tv) {
      parentKey = folderKey;
      try { await TmdService.instance.carryMeta(folderKey, TmdStore.identityKeyFor(item)); } catch (_) {}
    } else if (!isEp && folderMeta != null) {
      final videoKey = TmdStore.identityKeyFor(item);
      final existing = TmdService.instance.metaFor(videoKey);
      if (existing != null && existing.movie.id == folderMeta.movie.id) {
        try { await TmdService.instance.clear(videoKey); } catch (_) {}
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: item,
          parentMetadataKey: parentKey,
        ),
      ),
    );
    await _loadSmb();
  }

  Future<void> _openFtpEntry(FtpEntry entry) async {
    if (entry.isDirectory) {
      FocusScope.of(context).unfocus();
      setState(() {
        _currentPath = entry.path.replaceAll('//', '/').replaceAll(RegExp(r'/+$'), '');
        _loading = true;
      });
      await _loadFtp();
      return;
    }
    final item = _toVideoItem(entry);
    if (!mounted) return;
    // Use the subfolder-aware metadataKey so episodes in subfolders
    // resolve to the correct season.
    final folderName = _subfolderName;
    final folderKey = _atRoot
        ? widget.folder.metadataKey
        : '${widget.folder.metadataKey}/$folderName';
    final folderMeta = TmdService.instance.metaFor(folderKey);
    final parsed = ParsedFileName.parse(entry.name);
    final isEp = parsed.isEpisode || _epPattern.hasMatch(entry.name);
    String? parentKey;
    if (isEp && folderMeta != null && folderMeta.movie.kind == TmdKind.tv) {
      parentKey = folderKey;
      try { await TmdService.instance.carryMeta(folderKey, TmdStore.identityKeyFor(item)); } catch (_) {}
    } else if (!isEp && folderMeta != null) {
      final videoKey = TmdStore.identityKeyFor(item);
      final existing = TmdService.instance.metaFor(videoKey);
      if (existing != null && existing.movie.id == folderMeta.movie.id) {
        try { await TmdService.instance.clear(videoKey); } catch (_) {}
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: item,
          parentMetadataKey: parentKey,
        ),
      ),
    );
    await _loadFtp();
  }

  Future<void> _openUpnpEntry(UpnpEntry entry) async {
    if (entry.isDirectory) {
      FocusScope.of(context).unfocus();
      setState(() {
        _upnpCrumbs = [..._upnpCrumbs, (id: entry.id, name: entry.name)];
        _loading = true;
      });
      await _loadUpnp();
      return;
    }
    if (entry.url == null || entry.url!.isEmpty) return;
    final serverId = widget.folder.networkServerId ?? '';
    final key = 'upnp:$serverId/${entry.id}';
    // Jellyfin DLNA servers transcode items with external subtitles; play
    // the original bytes via the saved Jellyfin server when this URL is one.
    VideoItem? video = await JellyfinClient().upgradeDlnaUrl(
      url: entry.url!,
      title: entry.name,
      sizeBytes: entry.size,
    );
    if (video != null) {
      video = VideoItem(
        id: key,
        title: video.title,
        uri: video.uri,
        resumeKey: key,
        duration: video.duration,
        resolution: video.resolution,
        sizeBytes: video.sizeBytes,
        allowSelfSigned: video.allowSelfSigned,
        jellyfinServerId: video.jellyfinServerId,
        jellyfinItemId: video.jellyfinItemId,
        externalSubtitles: video.externalSubtitles,
        chapters: video.chapters,
      );
    }
    video ??= _toVideoItem(entry);
    if (!mounted) return;
    final folderName = _subfolderName;
    final folderKey = _atRoot
        ? widget.folder.metadataKey
        : '${widget.folder.metadataKey}/$folderName';
    final folderMeta = TmdService.instance.metaFor(folderKey);
    final parsed = ParsedFileName.parse(entry.name);
    final isEp = parsed.isEpisode || _epPattern.hasMatch(entry.name);
    String? parentKey;
    if (isEp && folderMeta != null && folderMeta.movie.kind == TmdKind.tv) {
      parentKey = folderKey;
      try { await TmdService.instance.carryMeta(folderKey, TmdStore.identityKeyFor(video)); } catch (_) {}
    } else if (!isEp && folderMeta != null) {
      final videoKey = TmdStore.identityKeyFor(video);
      final existing = TmdService.instance.metaFor(videoKey);
      if (existing != null && existing.movie.id == folderMeta.movie.id) {
        try { await TmdService.instance.clear(videoKey); } catch (_) {}
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: video,
          parentMetadataKey: parentKey,
        ),
      ),
    );
    await _loadUpnp();
  }

  /// Open a season folder entry from the poster grid. Navigates into the
  /// subfolder regardless of entry type (SMB, FileEntry, WebDAV, Jellyfin,
  /// FTP, UPnP).
  void _openSeasonFolder(Object entry) {
    if (_isSmb) {
      _openSmbEntry(entry as SmbEntry);
    } else if (_isJellyfin) {
      _openJellyfinItem(entry as JellyfinItem);
    } else if (entry is FileEntry) {
      _openEntry(entry);
    } else if (_isFtp && entry is FtpEntry) {
      _openFtpEntry(entry);
    } else if (_isUpnp && entry is UpnpEntry) {
      _openUpnpEntry(entry);
    } else if (_isWebDav && entry is WebDavEntry) {
      if (entry.isDirectory) {
        FocusScope.of(context).unfocus();
        setState(() {
          _currentPath = entry.path.replaceAll('//', '/').replaceAll(RegExp(r'/+$'), '');
          _loading = true;
        });
        _loadWebDav();
      }
    }
  }

  VideoItem _toVideoItem(Object entry) {
    // Bookmarked-tree videos come back as content:// URIs (no real file
    // path), so hand those to the player's `uri` field.
    String name;
    String path;
    String? resumeKey;
    int size;
    Uri? rawUri;
    bool isTranscoded = false;
    List<VideoExternalSub> externalSubs = const [];
    if (entry is SmbEntry) {
      name = entry.name;
      path = entry.path;
      resumeKey = 'smb:${widget.folder.networkServerId}/${widget.folder.networkShare}/${entry.path}';
      size = entry.size;
    } else if (entry is WebDavEntry) {
      name = entry.name;
      path = entry.path;
      resumeKey = 'webdav:${widget.folder.networkServerId}${entry.path}';
      size = entry.size;
    } else if (entry is FtpEntry) {
      name = entry.name;
      path = entry.path;
      final scheme = _ftpIsSftp ? 'sftp' : 'ftp';
      rawUri = Uri.parse('$scheme://${widget.folder.networkServerId}${_encodeFtpPath(entry.path)}');
      resumeKey = 'ftp_${widget.folder.networkServerId}${entry.path}';
      size = entry.size;
    } else if (entry is UpnpEntry) {
      name = entry.name;
      path = '';
      rawUri = entry.url != null && entry.url!.isNotEmpty ? Uri.parse(entry.url!) : null;
      resumeKey = 'upnp:${widget.folder.networkServerId}/${entry.id}';
      size = entry.size;
      isTranscoded = entry.transcoded;
      if (entry.externalSubs.isNotEmpty) {
        externalSubs = [
          for (final e in entry.externalSubs.asMap().entries)
            VideoExternalSub(
              uri: e.value.url,
              label: 'Subtitle ${e.key + 1} · ${e.value.extension.toUpperCase()}',
              mimeType: e.value.mimeType,
            ),
        ];
      }
    } else {
      final fe = entry as FileEntry;
      name = fe.name;
      path = fe.path;
      resumeKey = fe.resumeKey;
      size = fe.size;
    }
    final isContentUri = path.startsWith('content://');
    final info = extractFileInfo(name);
    return VideoItem(
      id: 'folder_${widget.folder.id}_${(path.isEmpty ? resumeKey ?? name : path).hashCode}',
      title: name,
      path: isContentUri ? null : (rawUri != null ? null : path),
      uri: isContentUri ? path : rawUri?.toString(),
      resumeKey: resumeKey,
      duration: Duration.zero,
      sizeBytes: size,
      isTranscoded: isTranscoded,
      externalSubtitles: externalSubs,
      videoCodec: info.videoCodec,
      audioCodec: info.audioCodec,
      audioChannels: info.audioChannels,
      audioLanguage: info.audioLanguage,
      resolution: info.resolution,
      fps: info.fps,
      hdrHint: info.hdrHint,
    );
  }

  static String _encodeFtpPath(String path) {
    final clean = path.startsWith('/') ? path : '/$path';
    return clean.split('/').map((s) => Uri.encodeComponent(s)).join('/');
  }

  /// Reloads the watched-mark set and resume positions for the current list.
  Future<void> _refreshWatched() async {
    try {
      final watched = await WatchedStore.load();
      if (mounted) setState(() => _watchedKeys = watched);
    } catch (_) {}
    await _refreshResumes();
  }

  /// Loads resume positions and durations for all non-directory entries so
  /// every tile can show a progress bar without an async lookup per tile.
  Future<void> _refreshResumes() async {
    final keys = <String>[];
    for (final e in _currentEntries) {
      final key = _watchedKeyForEntry(e);
      if (key != null && key.isNotEmpty) keys.add(key);
    }
    final result = await ResumeProgressHelper.load(keys);
    if (mounted) {
      setState(() {
        _resumePositionsMs = result.positions;
        _durationsMs = result.durations;
      });
    }
  }

  String? _watchedKeyForEntry(Object entry) {
    if (_isJellyfin) {
      final item = entry as JellyfinItem;
      final server = _jellyfinServer;
      if (server == null || item.isFolder) return null;
      return _jellyfin.videoItem(server, item).resumeKey;
    }
    if (_isSmb) {
      final e = entry as SmbEntry;
      if (e.isDirectory) return null;
      final serverId = widget.folder.networkServerId ?? '';
      final share = widget.folder.networkShare ?? _networkShare;
      return 'smb:$serverId/$share/${e.path}';
    }
    if (_isWebDav) {
      final wd = entry as WebDavEntry;
      if (wd.isDirectory) return null;
      final id = widget.folder.networkServerId ?? '';
      return 'webdav:$id${wd.path}';
    }
    if (_isFtp) {
      final e = entry as FtpEntry;
      if (e.isDirectory) return null;
      return 'ftp_${widget.folder.networkServerId ?? ''}${e.path}';
    }
    if (_isUpnp) {
      final e = entry as UpnpEntry;
      if (e.isDirectory) return null;
      return 'upnp:${widget.folder.networkServerId ?? ''}/${e.id}';
    }
    return (entry as FileEntry).isDirectory ? null : (entry.resumeKey ?? entry.path);
  }

  Future<void> _toggleWatched(Object entry) async {
    final key = _watchedKeyForEntry(entry);
    if (key == null || key.isEmpty) return;
    final now = !_watchedKeys.contains(key);
    setState(() {
      _watchedKeys = {..._watchedKeys};
      now ? _watchedKeys.add(key) : _watchedKeys.remove(key);
    });
    try {
      await WatchedStore.set(key, now);
    } catch (_) {}
  }

  /// Backfills already-watched shows/movies from SIMKL into the local watched
  /// store for this folder's entries (mirrors smb_screen.dart's sync button).
  Future<void> _syncFromSimkl() async {
    final client = SimklClient();
    if (!client.isConfigured) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).folderSimklNotConfigured)),
        );
      }
      return;
    }
    if (!await client.isAuthenticated()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).folderSimklSignInFirst)),
        );
      }
      return;
    }
    setState(() => _syncingSimkl = true);
    try {
      final watched = await client.fetchWatched();
      int marked = 0;
      for (final e in _currentEntries) {
        final key = _watchedKeyForEntry(e);
        if (key == null || key.isEmpty || _watchedKeys.contains(key)) continue;
        final meta = TmdService.instance
            .metaFor(TmdStore.identityKeyFor(_toVideoItem(e)));
        if (meta == null) continue;
        final id = meta.movie.id;
        final isTv = meta.movie.kind == TmdKind.tv;
        final shouldMark = isTv
            ? watched.showSeasons.containsKey(id)
            : watched.movieIds.contains(id);
        if (shouldMark) {
          await WatchedStore.set(key, true);
          marked++;
        }
      }
      await _refreshWatched();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              marked > 0
                  ? 'Marked $marked as watched from SIMKL'
                  : 'Nothing new from SIMKL',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('SIMKL sync failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _syncingSimkl = false);
    }
  }

  Future<void> _goUp() async {
    FocusScope.of(context).unfocus();
    if (_isJellyfin) {
      if (_jellyfinCrumbs.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _jellyfinCrumbs =
            _jellyfinCrumbs.sublist(0, _jellyfinCrumbs.length - 1);
        _loading = true;
      });
      await _loadJellyfin();
      return;
    }
    if (_isUpnp) {
      if (_upnpCrumbs.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      // Mirror the DLNA container hierarchy (root container id "0"): back
      // walks the crumb stack; each container is navigated by object id.
      setState(() {
        _upnpCrumbs = _upnpCrumbs.sublist(0, _upnpCrumbs.length - 1);
        _loading = true;
      });
      await _loadUpnp();
      return;
    }
    if (_atRoot) {
      Navigator.of(context).pop();
      return;
    }
    // When opened from TmdDetailsScreen with an initialPath, the first back
    // should pop back to TmdDetailsScreen — not navigate internally to root
    // and show the header/backdrop (which looks like a stale "still image").
    final parent = _parentOf(_currentPath);
    final fallback = _isNetworkFolder ? _networkPath : widget.folder.path;
    if (widget.initialPath != null && parent == fallback) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _currentPath = parent ?? fallback);
    await _load();
  }

  static String? _parentOf(String path) {
    final cleaned = path.replaceAll(RegExp(r'/+$'), '');
    final index = cleaned.lastIndexOf('/');
    if (index <= 0) return null;
    return cleaned.substring(0, index);
  }

  String get _title {
    if (_isJellyfin) {
      return _jellyfinCrumbs.isEmpty
          ? widget.folder.name
          : _jellyfinCrumbs.last.name;
    }
    if (_isUpnp) {
      return _upnpCrumbs.isEmpty
          ? widget.folder.name
          : _upnpCrumbs.last.name;
    }
    return _atRoot ? widget.folder.name : (_currentPath.split('/').lastOrNull ?? '');
  }

  /// The display name of the subfolder being viewed (used for TMDB
  /// metadata keys and title). UPnP uses the crumb name (the DLNA container
  /// name), not the object id; on the root it's the bookmark name.
  String get _subfolderName {
    if (_isUpnp) {
      if (_upnpCrumbs.isNotEmpty) return _upnpCrumbs.last.name;
      return widget.folder.name;
    }
    if (_atRoot) return widget.folder.name;
    return _currentPath.split('/').lastOrNull ?? widget.folder.name;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _goUp();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(_title),
        leading: IconButton(
          tooltip: 'Up',
          icon: const Icon(Icons.arrow_back),
          onPressed: _goUp,
        ),
        actions: [
          if (_enableSimklSync)
            IconButton(
              tooltip: 'Mark watched from SIMKL',
              icon: _syncingSimkl
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_done_outlined),
              onPressed: _syncingSimkl ? null : _syncFromSimkl,
            ),
        ],
      ),
      body: TvOverscan(child: _body(context)),
    ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _currentEntries.isEmpty) {
      return Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text(
          'Error: $_error',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    final entries = _currentEntries;
    if (entries.isEmpty) {
      return Column(
        children: [
          if (_atRoot) _header(context),
          Expanded(child: Center(child: Text(AppLocalizations.of(context).folderNoVideosHere))),
        ],
      );
    }

    // Series folder mode: show TMDB header + season-grouped episodes.
    if (_isSeriesFolder) {
      return _seriesFolderBody(context);
    }

    // Regular mode: folders + season-grouped videos.
    return _regularBody(context);
  }

  /// Nova-style "Seasons" poster-card grid, shown when the current folder
  /// contains season-like subfolders and the series' TMDB metadata (with
  /// season posters) is available. Tapping a card opens that season's folder.
  /// Shared by the series and regular bodies so both render identically.
  List<Widget> _seasonPosterGridSlivers(BuildContext context) {
    final all = _currentEntries;
    final folders = all.where(_isFolderEntry).toList();
    final seasonFolders = <Object>[];
    for (final f in folders) {
      final name = _nameOf(f);
      final s = _parseSeasonFromFolderName(name);
      if (s != null && s > 0) seasonFolders.add(f);
    }
    if (seasonFolders.isEmpty) return const [];
    final theme = Theme.of(context);
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        sliver: SliverToBoxAdapter(
          child: Text(
            'Seasons',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 0.58,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final entry = seasonFolders[index];
              final name = _nameOf(entry);
              final s = _parseSeasonFromFolderName(name);
              return _FolderSeasonPosterCard(
                seasonNumber: s,
                seasonPosterUrl: (s != null && _seriesMeta != null)
                    ? _seriesMeta!.seasons[s]?.posterUrl(width: 300)
                    : null,
                seasonName: (s != null && _seriesMeta?.seasons[s]?.name != null)
                    ? _seriesMeta!.seasons[s]!.name
                    : name,
                onTap: () => _openSeasonFolder(entry),
              );
            },
            childCount: seasonFolders.length,
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 4)),
    ];
  }

  /// Nova-style series folder body: series header (poster, title, rating,
  /// overview) at top, season-grouped episode list below.
  Widget _seriesFolderBody(BuildContext context) {
    final theme = Theme.of(context);
    final meta = _seriesMeta;
    final details = _seriesDetails;
    final metadataKey = widget.folder.metadataKey;

    if (_loadingSeriesMeta) {
      // TMDB metadata is still resolving — do NOT block the file list behind
      // a spinner. Files are the first priority; the Nova-style series header
      // (poster/title/overview) arrives as soon as the fetch completes and
      // this body swaps over via setState.
      return _regularBody(context);
    }

    // No metadata — fall back to regular list.
    if (meta == null) {
      return _regularBody(context);
    }

    // Separate folders from videos — include ALL video files, not just
    // those matching SxxExx patterns, so single episodes (E01, numbered)
    // still appear in the series body.
    final entries = _currentEntries;
    final episodes = <Object>[];
    for (final e in entries) {
      if (_isFolderEntry(e)) continue;
      episodes.add(e);
    }

    // Group by season.
    final seasonGroups = sg.groupBySeason<Object>(
      episodes,
      _seasonOf,
      _episodeOf,
    );
    final sortedSeasons = seasonGroups.keys.toList()..sort();

    // Auto-expand the first season.
    if (_expandedSeasons.isEmpty && sortedSeasons.isNotEmpty) {
      _expandedSeasons.add(sortedSeasons.first);
    }

    return CustomScrollView(
      key: ValueKey('series_$_currentPath'),
      slivers: [
        // ── Series header ──
        SliverToBoxAdapter(
          child: _SeriesHeader(
            meta: meta,
            details: details,
            metadataKey: metadataKey,
            folderSeason: _seriesMeta?.folderSeason,
            onFixMatch: () async {
              await _fixMatchSeries();
            },
            onRemoveInfo: () async {
              final service = TmdService.instance;
              await service.clear(metadataKey);
              if (!mounted) return;
              setState(() {
                _seriesMeta = null;
                _seriesDetails = null;
                _isSeriesFolder = false;
              });
            },
          ),
        ),

        // ── Season poster grid (season-subfolder folders) ──
        ..._seasonPosterGridSlivers(context),

        // ── Episodes section header ──
        if (episodes.isNotEmpty)
          SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Text(
                  'Episodes',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  '${episodes.length} ${episodes.length == 1 ? 'file' : 'files'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Season groups with expand/collapse ──
        for (final s in sortedSeasons) ...[
          Builder(builder: (context) {
            final seasonList = seasonGroups[s]!;
            final expanded = _expandedSeasons.contains(s);
            final watchedCount = sg.watchedCount(
              seasonList,
              _watchedKeys,
              _watchedKeyForEntry,
            );
            final total = seasonList.length;
            final cachedMeta = TmdService.instance.metaFor(metadataKey);
            return _FolderSeasonExpansion(
              season: s,
              expanded: expanded,
              onToggle: () {
                setState(() {
                  if (expanded) {
                    _expandedSeasons.remove(s);
                  } else {
                    _expandedSeasons.add(s);
                  }
                });
              },
              watchedCount: watchedCount,
              total: total,
              seasonName: cachedMeta?.seasons[s]?.name,
              child: Column(
                children: [
                  for (final v in seasonList) _tileFor(v),
                ],
              ),
            );
          }),
        ],

        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// Regular flat body (non-series folder).
  Widget _regularBody(BuildContext context) {
    final entries = _currentEntries;
    final theme = Theme.of(context);
    final folderName = _subfolderName;
    final metadataKey = _atRoot
        ? widget.folder.metadataKey
        : '${widget.folder.metadataKey}/$folderName';
    // Separate folders from playable videos so seasons group only videos.
    final folders = <Object>[];
    final videos = <Object>[];
    for (final e in entries) {
      final isFolder = _isFolderEntry(e);
      (isFolder ? folders : videos).add(e);
    }
    // Build season groups for episode videos; movies stay ungrouped.
    final episodes = videos.where(_isEpisode).toList();
    final movies = videos.where((v) => !_isEpisode(v)).toList();
    final seasonGroups = sg.groupBySeason<Object>(
      episodes,
      _seasonOf,
      _episodeOf,
    );
    final hasSeasons = seasonGroups.isNotEmpty;
    final sortedSeasons = seasonGroups.keys.toList()..sort();

    // Check if folders look like season subfolders (TMDB metadata optional).
    final seasonFolders = <Object>[];
    final otherFolders = <Object>[];
    for (final f in folders) {
      final s = _parseSeasonFromFolderName(_nameOf(f));
      if (s != null && s > 0) {
        seasonFolders.add(f);
      } else {
        otherFolders.add(f);
      }
    }
    final showSeasonGrid = seasonFolders.isNotEmpty;

    return Column(
      children: [
        if (_atRoot) _header(context),
        Expanded(
          child: showSeasonGrid
              ? CustomScrollView(
                  key: ValueKey('folder_$_currentPath'),
                  slivers: [
                    // ── Season poster grid ──
                    ..._seasonPosterGridSlivers(context),
                    // ── Other subfolders ──
                    if (otherFolders.isNotEmpty)
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => _tileFor(otherFolders[index]),
                          childCount: otherFolders.length,
                        ),
                      ),
                    // ── Season-grouped episodes ──
                    if (hasSeasons)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        sliver: SliverToBoxAdapter(
                          child: Text(
                            'Episodes',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    for (final s in sortedSeasons) ...[
                      SliverToBoxAdapter(
                        child: Builder(builder: (context) {
                          final seasonList = seasonGroups[s]!;
                          final expanded = _expandedSeasons.contains(s);
                          final watchedCount = sg.watchedCount(
                            seasonList,
                            _watchedKeys,
                            _watchedKeyForEntry,
                          );
                          final total = seasonList.length;
                          final cachedMeta =
                              TmdService.instance.metaFor(metadataKey);
                          return _FolderSeasonExpansion(
                            season: s,
                            expanded: expanded,
                            onToggle: () {
                              setState(() {
                                if (expanded) {
                                  _expandedSeasons.remove(s);
                                } else {
                                  _expandedSeasons.add(s);
                                }
                              });
                            },
                            watchedCount: watchedCount,
                            total: total,
                            seasonName: cachedMeta?.seasons[s]?.name,
                            child: Column(
                              children: [
                                for (final v in seasonList) _tileFor(v),
                              ],
                            ),
                          );
                        }),
                      ),
                    ],
                    // ── Movies ──
                    if (movies.isNotEmpty)
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => _tileFor(movies[index]),
                          childCount: movies.length,
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                )
              : ListView(
                  key: ValueKey('folder_$_currentPath'),
                  children: [
                    for (final f in folders) _tileFor(f),
              if (hasSeasons)
                for (final s in sortedSeasons) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Row(
                      children: [
                        Text(
                          sg.seasonHeader(s),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        SizedBox(width: 8),
                        Builder(builder: (context) {
                          final seasonList = seasonGroups[s]!;
                          final watched = sg.watchedCount(
                            seasonList,
                            _watchedKeys,
                            _watchedKeyForEntry,
                          );
                          final total = seasonList.length;
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SeasonProgressRing(
                                watched: watched,
                                total: total,
                                size: 28,
                                strokeWidth: 2.5,
                              ),
                              SizedBox(width: 6),
                              Text(
                                sg.watchedBadge(watched, total),
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          );
                        }),
                      ],
                    ),
                  ),
                  for (final v in seasonGroups[s]!) _tileFor(v),
                ],
              for (final m in movies) _tileFor(m),
            ],
          ),
        ),
      ],
    );
  }

  /// Builds a tile for any entry type.
  Widget _tileFor(Object e) {
    if (_isJellyfin) {
      final item = e as JellyfinItem;
      final key = _watchedKeyForEntry(item);
      return _JellyfinFolderTile(
        item: item,
        tmdbMeta: item.isFolder ? null : _tmdbForJellyfin(item),
        watched: _watchedKeys.contains(key),
        onToggleWatched: () => _toggleWatched(item),
        resumePositionMs: _resumePositionsMs[key],
        durationMs: _durationsMs[key],
        onTap: () => _openJellyfinItem(item),
      );
    }
    if (_isSmb) {
      final smb = e as SmbEntry;
      final key = _watchedKeyForEntry(smb);
      return _FolderTile(
        entry: FileEntry(
            name: smb.name,
            path: smb.path,
            isDirectory: smb.isDirectory,
            size: smb.size,
            resumeKey: key),
        tmdbMeta: smb.isDirectory ? null : _tmdbForSmb(smb),
        watched: _watchedKeys.contains(key),
        onToggleWatched: () => _toggleWatched(smb),
        episode: smb.isDirectory ? null : _episodeFor(smb),
        folderSeason: _seriesMeta?.folderSeason,
        resumePositionMs: _resumePositionsMs[key],
        durationMs: _durationsMs[key],
        effectiveSize: _smbFileSizes[smb.path],
        onTap: () => _openSmbEntry(smb),
      );
    }
    if (_isWebDav) {
      final wd = e as WebDavEntry;
      final key = _watchedKeyForEntry(wd);
      return _FolderTile(
        entry: FileEntry(
          name: wd.name,
          path: wd.path,
          isDirectory: wd.isDirectory,
          size: wd.size,
          resumeKey: key,
        ),
        tmdbMeta: wd.isDirectory ? null : _tmdbForWebDav(wd),
        watched: _watchedKeys.contains(key),
        onToggleWatched: () => _toggleWatched(wd),
        episode: wd.isDirectory ? null : _episodeFor(wd),
        folderSeason: _seriesMeta?.folderSeason,
        resumePositionMs: _resumePositionsMs[key],
        durationMs: _durationsMs[key],
        onTap: () => _openWebDavEntry(wd),
      );
    }
    if (_isFtp) {
      final ftp = e as FtpEntry;
      final key = _watchedKeyForEntry(ftp);
      return _FolderTile(
        entry: FileEntry(
          name: ftp.name,
          path: ftp.path,
          isDirectory: ftp.isDirectory,
          size: ftp.size,
          resumeKey: key,
        ),
        tmdbMeta: ftp.isDirectory ? null : _tmdbForFtp(ftp),
        watched: _watchedKeys.contains(key),
        onToggleWatched: () => _toggleWatched(ftp),
        episode: ftp.isDirectory ? null : _episodeFor(ftp),
        folderSeason: _seriesMeta?.folderSeason,
        resumePositionMs: _resumePositionsMs[key],
        durationMs: _durationsMs[key],
        onTap: () => _openFtpEntry(ftp),
      );
    }
    if (_isUpnp) {
      final upnp = e as UpnpEntry;
      final key = _watchedKeyForEntry(upnp);
      return _FolderTile(
        entry: FileEntry(
          name: upnp.name,
          path: upnp.name,
          isDirectory: upnp.isDirectory,
          size: upnp.size,
          resumeKey: key,
        ),
        tmdbMeta: upnp.isDirectory ? null : _tmdbForUpnp(upnp),
        watched: _watchedKeys.contains(key),
        onToggleWatched: () => _toggleWatched(upnp),
        episode: upnp.isDirectory ? null : _episodeFor(upnp),
        folderSeason: _seriesMeta?.folderSeason,
        resumePositionMs: _resumePositionsMs[key],
        durationMs: _durationsMs[key],
        onTap: () => _openUpnpEntry(upnp),
      );
    }
    final fileEntry = e as FileEntry;
    final key = _watchedKeyForEntry(fileEntry);
    return _FolderTile(
      entry: fileEntry,
      tmdbMeta: fileEntry.isDirectory ? null : _tmdbFor(fileEntry),
      watched: _watchedKeys.contains(key),
      onToggleWatched: () => _toggleWatched(fileEntry),
      episode: fileEntry.isDirectory ? null : _episodeFor(fileEntry),
      folderSeason: _seriesMeta?.folderSeason,
      resumePositionMs: _resumePositionsMs[key],
      durationMs: _durationsMs[key],
      onTap: () => _openEntry(fileEntry),
    );
  }

  /// Fix match for the series folder — opens the TMDB search dialog.
  Future<void> _fixMatchSeries() async {
    final metadataKey = widget.folder.metadataKey;
    final folderName = widget.folder.name;
    final parsed = ParsedFileName.parse(folderName);
    final picked = await showDialog<TmdMovie>(
      context: context,
      builder: (context) => _FolderSearchDialog(
        initialQuery: parsed.title.isNotEmpty ? parsed.title : folderName,
        initialYear: parsed.year,
        initialKind: TmdKind.tv,
      ),
    );
    if (picked == null || !mounted) return;

    final service = TmdService.instance;
    await service.setManualFolder(metadataKey, picked);
    if (!mounted) return;

    setState(() {
      _loadingSeriesMeta = true;
    });
    final meta = service.metaFor(metadataKey);
    final details = await service.detailsFor(metadataKey);
    if (!mounted) return;

    setState(() {
      _seriesMeta = meta;
      _seriesDetails = details;
      _loadingSeriesMeta = false;
      _isSeriesFolder = true;
    });
  }

  bool _isFolderEntry(Object e) {
    if (_isJellyfin) return (e as JellyfinItem).isFolder;
    if (_isSmb) return (e as SmbEntry).isDirectory;
    if (_isWebDav) return (e as WebDavEntry).isDirectory;
    if (_isFtp) return (e as FtpEntry).isDirectory;
    if (_isUpnp) return (e as UpnpEntry).isDirectory;
    return (e as FileEntry).isDirectory;
  }

  static final _epPattern = RegExp(
      r'\b(?:S\d{1,2}E\d{1,2}|\d{1,2}x\d{1,3}|E(?:P)?\d{1,3})\b|\[(\d{1,3})\]',
      caseSensitive: false);

  bool _isEpisode(Object e) {
    if (_isJellyfin) return (e as JellyfinItem).type == 'Episode';
    if (_isSmb) {
      final smb = e as SmbEntry;
      final p = ParsedFileName.parse(smb.name);
      return p.isEpisode || _epPattern.hasMatch(smb.name);
    }
    if (_isWebDav) {
      final name = (e as WebDavEntry).name;
      final p = ParsedFileName.parse(name);
      return p.isEpisode || _epPattern.hasMatch(name);
    }
    if (_isFtp) {
      final name = (e as FtpEntry).name;
      final p = ParsedFileName.parse(name);
      return p.isEpisode || _epPattern.hasMatch(name);
    }
    if (_isUpnp) {
      final name = (e as UpnpEntry).name;
      final p = ParsedFileName.parse(name);
      return p.isEpisode || _epPattern.hasMatch(name);
    }
    final fe = e as FileEntry;
    final p = ParsedFileName.parse(fe.name);
    return p.isEpisode || _epPattern.hasMatch(fe.name);
  }

  String _nameOf(Object e) {
    if (_isJellyfin) return (e as JellyfinItem).name;
    if (_isSmb) return (e as SmbEntry).name;
    if (_isWebDav) return (e as WebDavEntry).name;
    if (_isFtp) return (e as FtpEntry).name;
    if (_isUpnp) return (e as UpnpEntry).name;
    return (e as FileEntry).name;
  }

  int _seasonOf(Object e) {
    final folderSeason = _seriesMeta?.folderSeason;
    if (folderSeason != null) return folderSeason;
    int parsedSeason;
    if (_isJellyfin) {
      parsedSeason = (e as JellyfinItem).parentIndexNumber ?? 0;
    } else if (_isSmb) {
      parsedSeason = ParsedFileName.parse((e as SmbEntry).name).season;
    } else if (_isWebDav) {
      final name = (e as WebDavEntry).name;
      parsedSeason = ParsedFileName.parse(name).season;
    } else if (_isFtp) {
      parsedSeason = ParsedFileName.parse((e as FtpEntry).name).season;
    } else if (_isUpnp) {
      parsedSeason = ParsedFileName.parse((e as UpnpEntry).name).season;
    } else {
      parsedSeason = ParsedFileName.parse((e as FileEntry).name).season;
    }
    // For anime bracket numbering ([01]/[02]), parsed.season is 0 but the
    // show is a single season — fall back to the first season with TMDB
    // data so episodes group under the right header.
    if (parsedSeason <= 0 && _seriesMeta != null && _seriesMeta!.seasons.isNotEmpty) {
      return _seriesMeta!.seasons.keys.first;
    }
    return parsedSeason;
  }

  TmdEpisode? _episodeFor(Object e) {
    final folderSeason = _seriesMeta?.folderSeason;
    int parsedSeason;
    int parsedEpisode;
    if (_isSmb) {
      final smb = e as SmbEntry;
      final parsed = ParsedFileName.parse(smb.name);
      if (!parsed.isEpisode) return null;
      parsedSeason = parsed.season;
      parsedEpisode = parsed.episode;
    } else {
      final parsed = ParsedFileName.parse(_nameOf(e));
      if (!parsed.isEpisode) return null;
      parsedSeason = parsed.season;
      parsedEpisode = parsed.episode;
    }
    int s;
    if (folderSeason != null) {
      s = folderSeason;
    } else if (parsedSeason > 0) {
      s = parsedSeason;
    } else if (_seriesMeta?.seasons.isNotEmpty == true) {
      // Anime bracket numbering ([01]/[02]) — use the first season with
      // fetched TMDB data so episodes resolve to the right episode object.
      s = _seriesMeta!.seasons.keys.first;
    } else {
      s = 1;
    }
    return _seriesMeta?.seasons[s]?.episode(parsedEpisode);
  }

  int _episodeOf(Object e) {
    if (_isJellyfin) return (e as JellyfinItem).indexNumber ?? 0;
    if (_isSmb) return ParsedFileName.parse((e as SmbEntry).name).episode;
    if (_isWebDav) {
      final name = (e as WebDavEntry).name;
      return ParsedFileName.parse(name).episode;
    }
    if (_isFtp) return ParsedFileName.parse((e as FtpEntry).name).episode;
    if (_isUpnp) return ParsedFileName.parse((e as UpnpEntry).name).episode;
    return ParsedFileName.parse((e as FileEntry).name).episode;
  }

  /// The entries for the current mode (files / Jellyfin / network), unified.
  List<Object> get _currentEntries {
    if (_isJellyfin) return _jellyfinEntries;
    if (_isSmb) return _smbEntries;
    if (_isWebDav) return _networkEntries;
    if (_isFtp) return _ftpEntries;
    if (_isUpnp) return _upnpEntries;
    return _entries;
  }

  /// Cached TMDB meta for a video file, looked up under the same identity key
  /// its tile/tap uses so the poster and the opened details screen agree.
  TmdMeta? _tmdbFor(FileEntry entry) {
    if (_isJellyfin) return null;
    return TmdService.instance
        .metaFor(TmdStore.identityKeyFor(_toVideoItem(entry)));
  }

  TmdMeta? _tmdbForSmb(SmbEntry entry) {
    final serverId = widget.folder.networkServerId ?? '';
    final share = widget.folder.networkShare ?? _networkShare;
    final key = 'smb:$serverId/$share/${entry.path}';
    return TmdService.instance.metaFor(key);
  }

  TmdMeta? _tmdbForFtp(FtpEntry entry) {
    final serverId = widget.folder.networkServerId ?? '';
    final key = 'ftp_$serverId${entry.path}';
    return TmdService.instance.metaFor(key);
  }

  TmdMeta? _tmdbForWebDav(WebDavEntry entry) {
    final serverId = widget.folder.networkServerId ?? '';
    final key = 'webdav:$serverId${entry.path}';
    return TmdService.instance.metaFor(key);
  }

  TmdMeta? _tmdbForUpnp(UpnpEntry entry) {
    final serverId = widget.folder.networkServerId ?? '';
    final key = 'upnp:$serverId/${entry.id}';
    return TmdService.instance.metaFor(key);
  }

  /// Cached TMDB meta for a Jellyfin playable (same key as its tap).
  TmdMeta? _tmdbForJellyfin(JellyfinItem item) {
    final server = _jellyfinServer;
    if (server == null) return null;
    return TmdService.instance
        .metaFor(TmdStore.identityKeyFor(_jellyfin.videoItem(server, item)));
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final meta = TmdService.instance.metaFor(widget.folder.metadataKey);
    final movie = meta?.movie;
    final backdrop = movie?.backdropUrl();
    // Network folders (SMB/WebDAV) keep their entries in _smbEntries /
    // _networkEntries, so read from the unified _currentEntries — never the
    // local _entries list (which is empty for them and would read "0 videos").
    final all = _currentEntries;
    final videoCount = all.where((e) => !_isFolderEntry(e)).length;
    final folderCount = all.where(_isFolderEntry).length;

    return SizedBox(
      width: double.infinity,
      child: Stack(
        children: [
          if (backdrop != null)
            Image.network(
              backdrop,
              height: 140,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : const SizedBox.shrink(),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: backdrop != null ? 0.55 : 0.0),
                  Colors.transparent,
                ],
              ),
            ),
            // The AppBar already shows the title, so the header only carries
            // the metadata line (year, kind, video/folder counts) — never a
            // second copy of the title.
            child: Text(
              _headerSubtitle(movie, videoCount, folderCount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _headerSubtitle(TmdMovie? movie, int videoCount, int folderCount) {
    final countParts = <String>[
      videoCount == 1 ? '1 video' : '$videoCount videos',
      if (folderCount > 0)
        folderCount == 1 ? '1 folder' : '$folderCount folders',
    ];
    final countLabel = countParts.join(' · ');
    if (movie == null) return countLabel;
    final parts = <String>[
      if (movie.kind == TmdKind.tv) 'TV Series',
      if (movie.year != null) '${movie.year}',
      countLabel,
    ];
    return parts.join(' · ');
  }
}

/// A Jellyfin folder/playable tile for the folder screen's item list.
class _JellyfinFolderTile extends StatelessWidget {
  const _JellyfinFolderTile({
    required this.item,
    required this.tmdbMeta,
    required this.onTap,
    this.watched = false,
    this.onToggleWatched,
    this.resumePositionMs,
    this.durationMs,
  });

  final JellyfinItem item;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;
  final bool watched;
  final VoidCallback? onToggleWatched;
  final int? resumePositionMs;
  final int? durationMs;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (item.isFolder) {
      return TvTile(
        leading: Icon(Icons.folder, color: colorScheme.primary),
        title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );
    }

    final subtitle = <String>[
      if (item.seasonLabel.isNotEmpty) item.seasonLabel,
      if (item.sizeLabel.isNotEmpty) item.sizeLabel,
    ].where((s) => s.isNotEmpty).join(' · ');

    final posterUrl = posterUrlOf(tmdbMeta);

    final double? progress = (resumePositionMs != null &&
            resumePositionMs! > 0 &&
            durationMs != null &&
            durationMs! > 0)
        ? (resumePositionMs! / durationMs!).clamp(0.0, 1.0)
        : null;

    final subtitleWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (subtitle.isNotEmpty) Text(subtitle),
        if (progress != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(1),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
            ),
          ),
      ],
    );

    return TvTile(
      leading: posterUrl != null
          ? _Poster(posterUrl: posterUrl)
          : Icon(
              item.seasonLabel.isNotEmpty
                  ? Icons.movie_outlined
                  : Icons.play_circle_outline,
              color: colorScheme.secondary,
            ),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitleWidget,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: watched ? 'Mark as unwatched' : 'Mark as watched',
            icon: Icon(
              watched ? Icons.check_circle : Icons.check_circle_outline,
              color:
                  watched ? Colors.green.shade400 : colorScheme.onSurfaceVariant,
            ),
            onPressed: onToggleWatched,
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.entry,
    required this.tmdbMeta,
    required this.onTap,
    this.watched = false,
    this.onToggleWatched,
    this.episode,
    this.folderSeason,
    this.resumePositionMs,
    this.durationMs,
    this.effectiveSize,
  });

  final FileEntry entry;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;
  final bool watched;
  final VoidCallback? onToggleWatched;
  final TmdEpisode? episode;
  final int? folderSeason;
  final int? resumePositionMs;
  final int? durationMs;

  /// Background-fetched file size (bytes), overriding entry.size which is 0
  /// when the native listing skipped per-file length() for performance.
  final int? effectiveSize;

  static String _sizeLabel(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (entry.isDirectory) {
      return TvTile(
        leading: Icon(Icons.folder, color: colorScheme.primary),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );
    }

    final parsed = ParsedFileName.parse(entry.name);
    final effectiveSeason = folderSeason ?? parsed.season;
    final effectiveLabel = parsed.isEpisode
        ? 'S${effectiveSeason.toString().padLeft(2, '0')}E${parsed.episode.toString().padLeft(2, '0')}'
        : '';
    final stillUrl = episode?.stillUrl();

    final double? progress = (resumePositionMs != null &&
            resumePositionMs! > 0 &&
            durationMs != null &&
            durationMs! > 0)
        ? (resumePositionMs! / durationMs!).clamp(0.0, 1.0)
        : null;

    final hasOverviewText = episode != null && episode!.overview.isNotEmpty;
    final fileSizeLabel = _sizeLabel(effectiveSize ?? entry.size);
    final hasFileSize = fileSizeLabel.isNotEmpty;
    final ratingValue = episode?.voteAverage ?? 0;
    final hasRating = ratingValue > 0;

    final titleWidget = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (parsed.isEpisode) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              effectiveLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onPrimaryContainer,
                  ),
            ),
          ),
          SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            episode?.nameLabel ?? parsed.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
        ),
        if (hasRating) ...[
          SizedBox(width: 6),
          const Icon(Icons.star, size: 13, color: Colors.amber),
          SizedBox(width: 2),
          Text(
            ratingValue.toStringAsFixed(1),
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (watched)
          const Padding(
            padding: EdgeInsets.only(left: 6),
            child: Icon(Icons.check_circle, color: Colors.green, size: 18),
          ),
      ],
    );

    final subtitleWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasOverviewText)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              episode!.overview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        if (hasFileSize)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              fileSizeLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        if (progress != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(1),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                backgroundColor: colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
            ),
          ),
      ],
    );

    return TvTile(
      leading: stillUrl != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                stillUrl,
                width: 64,
                height: 40,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(
                  Icons.movie_outlined,
                  color: colorScheme.secondary,
                ),
              ),
            )
          : Icon(Icons.movie_outlined, color: colorScheme.secondary),
      title: titleWidget,
      subtitle: subtitleWidget,
      onTap: onTap,
    );
  }

}

/// Nova-style series folder header: poster + title + year + rating + genres +
/// overview, shown at the top of the series folder view.
class _SeriesHeader extends StatelessWidget {
  const _SeriesHeader({
    required this.meta,
    required this.metadataKey,
    required this.onFixMatch,
    required this.onRemoveInfo,
    this.details,
    this.folderSeason,
  });

  final TmdMeta meta;
  final TmdDetails? details;
  final String metadataKey;
  final VoidCallback onFixMatch;
  final VoidCallback onRemoveInfo;
  final int? folderSeason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final movie = meta.movie;

    // When a specific season folder is open, prefer its poster/name/overview
    // over the series-level ones.
    final season = folderSeason != null ? meta.seasons[folderSeason!] : null;
    final seasonPosterUrl = season?.posterUrl(width: 342);
    final posterUrl = seasonPosterUrl ?? movie.posterUrl(width: 342);

    // Use season name when it differs from the series title (e.g.
    // "Strike the Blood Final" vs "Strike the Blood").
    final seasonName = season?.name ?? '';
    final displayName = (seasonName.isNotEmpty && seasonName != movie.title)
        ? seasonName
        : movie.title;

    // Season overview — show ONLY the season's own text. TMDB leaves most
    // seasons without an overview, so a season folder renders blank rather
    // than repeating the base show's synopsis.
    final seasonOverview = season?.overview ?? '';
    final displayOverview = season != null
        ? seasonOverview
        : (details?.overview ?? '');

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: posterUrl != null
                    ? Image.network(
                        posterUrl,
                        width: 104,
                        height: 156,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _posterFallback(colorScheme),
                      )
                    : _posterFallback(colorScheme),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (displayName.isNotEmpty)
                      Text(
                        displayName,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (movie.year != null)
                      Text(
                        '${movie.year}',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    SizedBox(height: 4),
                    _RatingBadge(rating: movie.voteAverage),
                    SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (details?.genres != null)
                          for (final genre in details!.genres)
                            _FactChip(label: genre),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (displayOverview.isNotEmpty) ...[
            SizedBox(height: 20),
            Text(
              'Overview',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 6),
            Text(
              displayOverview,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
          if (details != null && details!.cast.isNotEmpty) ...[
            SizedBox(height: 20),
            _CastRow(cast: details!.cast),
          ],
          SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: onFixMatch,
                child: Text(AppLocalizations.of(context).detailsFixMatch),
              ),
              TextButton(
                onPressed: onRemoveInfo,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                child: Text(AppLocalizations.of(context).detailsRemoveInfo),
              ),
            ],
          ),
          SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Season expansion tile for the folder series view.
class _FolderSeasonExpansion extends StatelessWidget {
  const _FolderSeasonExpansion({
    required this.season,
    required this.expanded,
    required this.onToggle,
    required this.watchedCount,
    required this.total,
    required this.child,
    this.seasonName,
  });

  final int season;
  final bool expanded;
  final VoidCallback onToggle;
  final int watchedCount;
  final int total;
  final Widget child;
  final String? seasonName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final label = seasonName != null && seasonName!.isNotEmpty
        ? 'Season $season · $seasonName'
        : 'Season $season';

    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  SeasonProgressRing(
                    watched: watchedCount,
                    total: total,
                    size: 28,
                    strokeWidth: 2.5,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '$watchedCount/$total',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(width: 4),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) child,
        ],
      ),
    );
  }
}

/// Manual search dialog for fixing TMDB matches on folder series.
class _FolderSearchDialog extends StatefulWidget {
  const _FolderSearchDialog({this.initialQuery, this.initialYear, this.initialKind});

  final String? initialQuery;
  final int? initialYear;
  final TmdKind? initialKind;

  @override
  State<_FolderSearchDialog> createState() => _FolderSearchDialogState();
}

class _FolderSearchDialogState extends State<_FolderSearchDialog> {
  final _controller = TextEditingController();
  final _api = TmdApi();

  List<TmdMovie>? _results;
  bool _searching = false;
  bool _noKey = false;
  String? _error;
  late TmdKind _kind;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery ?? '';
    _kind = widget.initialKind ?? TmdKind.tv;
    if (_controller.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    final key = await _api.effectiveApiKey();
    if (!mounted) return;
    if (key.isEmpty) {
      setState(() {
        _searching = false;
        _results = null;
        _noKey = true;
      });
      return;
    }
    setState(() {
      _searching = true;
      _results = null;
      _error = null;
      _noKey = false;
    });
    try {
      final primary = await _api.search(
        query,
        year: widget.initialYear,
        kind: _kind,
      );
      final fallbackKind = _kind == TmdKind.tv ? TmdKind.movie : TmdKind.tv;
      final fallback = await _api.search(query, kind: fallbackKind);
      final results = <TmdMovie>[...primary, ...fallback];
      final seen = <int>{};
      results.removeWhere((m) => !seen.add(m.id));
      if (!mounted) return;
      setState(() => _results = results);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(AppLocalizations.of(context).detailsGetInfo),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Search title',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            SizedBox(height: 8),
            SegmentedButton<TmdKind>(
              segments: [
                ButtonSegment(value: TmdKind.tv, label: Text(AppLocalizations.of(context).detailsTvSeries)),
                ButtonSegment(value: TmdKind.movie, label: Text(AppLocalizations.of(context).detailsMovie)),
              ],
              selected: {_kind},
              onSelectionChanged: (sel) => setState(() => _kind = sel.first),
            ),
            SizedBox(height: 8),
            if (_searching)
              Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_noKey)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Search is unavailable right now. Try again in a moment.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Search failed. Try again in a moment.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colorScheme.error),
                ),
              )
            else if (_results != null)
              if (_results!.isEmpty)
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(AppLocalizations.of(context).detailsNoResults),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _results!.length,
                    itemBuilder: (context, index) {
                      final movie = _results![index];
                      return ListTile(
                        leading: movie.posterUrl(width: 92) != null
                            ? Image.network(
                                movie.posterUrl(width: 92)!,
                                width: 36,
                                height: 54,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.movie),
                              )
                            : const Icon(Icons.movie),
                        title: Text(movie.title),
                        subtitle: Text(
                          [
                            if (movie.kind == TmdKind.tv) 'TV Series',
                            if (movie.year != null) '${movie.year}',
                            if (movie.voteAverage > 0)
                              movie.voteAverage.toStringAsFixed(1),
                          ].join('  ·  '),
                        ),
                        onTap: () => Navigator.of(context).pop(movie),
                      );
                    },
                  ),
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppLocalizations.of(context).commonCancel),
        ),
      ],
    );
  }
}

/// Nova-style rating badge.
class _RatingBadge extends StatelessWidget {
  const _RatingBadge({required this.rating});
  final double rating;

  @override
  Widget build(BuildContext context) {
    if (rating <= 0) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, size: 14, color: Colors.amber),
          SizedBox(width: 4),
          Text(
            rating.toStringAsFixed(1),
            style: TextStyle(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// Fact chip for genres.
class _FactChip extends StatelessWidget {
  const _FactChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Horizontal cast row with circular photos.
class _CastRow extends StatelessWidget {
  const _CastRow({required this.cast});
  final List<TmdCastMember> cast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cast',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: 10),
        SizedBox(
          height: 130,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cast.length,
            separatorBuilder: (_, _) => SizedBox(width: 12),
            itemBuilder: (context, index) {
              final member = cast[index];
              return SizedBox(
                width: 80,
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(40),
                      child: member.profileUrl() != null
                          ? Image.network(
                              member.profileUrl()!,
                              width: 72,
                              height: 72,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  _avatarFallback(colorScheme, member.name),
                            )
                          : _avatarFallback(colorScheme, member.name),
                    ),
                    SizedBox(height: 6),
                    Text(
                      member.name,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    if (member.character != null &&
                        member.character!.isNotEmpty)
                      Text(
                        member.character!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 10,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  static Widget _avatarFallback(ColorScheme colorScheme, String name) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

Widget _posterFallback(ColorScheme colorScheme) {
  return Container(
    width: 104,
    height: 156,
    decoration: BoxDecoration(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(Icons.movie, color: colorScheme.onSurfaceVariant),
  );
}

/// A small 48×72 rounded poster thumbnail for a file row.
class _Poster extends StatelessWidget {
  const _Poster({required this.posterUrl});

  final String posterUrl;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        posterUrl,
        width: 48,
        height: 72,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Icon(
          Icons.play_circle_outline,
          color: Theme.of(context).colorScheme.secondary,
        ),
      ),
    );
  }
}

/// Poster card for a season subfolder. Shows the TMDB season poster (or a
/// gradient placeholder) + season name.
class _FolderSeasonPosterCard extends StatelessWidget {
  const _FolderSeasonPosterCard({
    this.seasonNumber,
    this.seasonPosterUrl,
    required this.seasonName,
    required this.onTap,
  });

  final int? seasonNumber;
  final String? seasonPosterUrl;
  final String seasonName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: seasonPosterUrl != null
                  ? Image.network(
                      seasonPosterUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _placeholder(colorScheme),
                    )
                  : _placeholder(colorScheme),
            ),
          ),
          const SizedBox(height: 4),
          // Fixed two-line slot so every poster area in the grid stays the
          // same size whether or not the season name wraps.
          SizedBox(
            height: (theme.textTheme.bodySmall?.fontSize ?? 12) * 1.4 * 2,
            child: Text(
              seasonName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer,
            colorScheme.secondaryContainer,
          ],
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: seasonNumber != null
            ? Text(
                'S${seasonNumber.toString().padLeft(2, '0')}',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onPrimaryContainer,
                ),
              )
            : Icon(
                Icons.folder,
                size: 32,
                color: colorScheme.onPrimaryContainer,
              ),
      ),
    );
  }
}
