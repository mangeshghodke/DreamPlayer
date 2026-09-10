import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart' show appRouteObserver;
import '../l10n/app_localizations.dart';
import '../models/video_item.dart';
import '../services/continue_watching.dart';
import '../services/download_manager.dart';
import '../services/file_browser.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/series_grouping.dart';
import '../services/tmdb_client.dart';
import '../services/webdav_client.dart';
import '../widgets/folder_card.dart';
import '../widgets/tv_text_field.dart';
import 'ftp_screen.dart';
import 'player_screen.dart';
import 'series_seasons_screen.dart';
import 'settings_screen.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/video_card.dart';
import '../utils/tv_helper.dart';
import 'file_browser_screen.dart';
import 'jellyfin_screen.dart';
import '../utils/file_info_extractor.dart';
import '../utils/startup_permissions.dart';
import 'smb_screen.dart';
import 'tmd_details_screen.dart';
import 'upnp_screen.dart';
import 'webdav_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.refreshTick});

  /// Notifies the screen that it became visible again (e.g. the Library tab
  /// was re-selected) so it can reload its continue-watching list.
  final Listenable? refreshTick;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, RouteAware {
  /// "Continue watching": videos with a saved resume position, most recently
  /// played first (persisted via [ContinueWatchingStore]).
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  List<ContinueWatchingEntry> _entries = const [];

  /// "Your library": the folders the user added (e.g. TV-show folders), most
  /// recently added first. Nothing is auto-scanned — only these appear.
  List<LibraryFolder> _folders = const [];

  /// Flux-style grouping: folders that share a base series name
  /// (`Strike the Blood`, `Strike the Blood II`, `Strike the Blood III`,
  /// `Strike the Blood IV`) collapse into one entry so they appear as a
  /// single card on the library grid.
  List<SeriesGroup> _seriesGroups = const [];

  /// Cached server-side metadata for the [JellyfinItemInfo] folders, keyed by
  /// `LibraryFolder.id` (fetch-on-bookmark, refreshed on open).
  Map<String, JellyfinItemInfo> _jellyfinMeta = const {};

  final JellyfinClient _client = JellyfinClient();

  /// Scrolls the home list back to the top after returning from playback, so
  /// the app-bar title and "Continue watching" heading are visible again.
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.refreshTick?.addListener(_loadLibrary);
    // Reload whenever the persisted list changes (e.g. a save or remove).
    ContinueWatchingStore.changes.addListener(_loadLibrary);
    LibraryFoldersStore.changes.addListener(_loadLibrary);
    // Update cards when TMDB metadata resolves for a visible entry.
    TmdService.instance.addListener(_onMetadataChanged);
    // Rebuild the downloads grid when a download completes/is deleted.
    DownloadManager.instance.addListener(_onMetadataChanged);
    // Open the drawer when the download notification is tapped.
    DownloadManager.instance.onNotificationTap = _openDownloadsDrawer;
    _loadLibrary();
    // Ask for every runtime permission at app open instead of mid-playback.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(requestStartupPermissions(context));
      _showTmdbHintOnce();
    });
  }

  void _onMetadataChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _showTmdbHintOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('dreamplayer.tmdbHintShown') == true) return;
    await prefs.setBool('dreamplayer.tmdbHintShown', true);
    if (!mounted) return;
    final theme = Theme.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.movie_filter, size: 40),
        title: Text(AppLocalizations.of(context).tmdbHintEnable),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'DreamPlayer can fetch movie posters, ratings, cast, and other '
              'details from The Movie Database (TMDB).\n\n'
              'Enter your free TMDB API key in Settings → Metadata to enable '
              'this feature.',
              style: theme.textTheme.bodySmall,
            ),
            SizedBox(height: 4),
            TextButton.icon(
              onPressed: () async {
                // Call launchUrl directly (no canLaunchUrl gate) — matches
                // openSupportUrl. canLaunchUrl returns false on Android 11+
                // for https VIEW intents and would silently swallow the tap.
                // Points at the login page: the API settings page requires
                // login first, so an logged-out user would land there anyway.
                final uri = Uri.parse('https://www.themoviedb.org/login');
                try {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } catch (_) {}
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(AppLocalizations.of(context).tmdbGetKey),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.of(context).commonClose),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Defer the push until the dialog pop completes, and wrap in
              // a Scaffold with AppBar — SettingsScreen is built for the
              // tab IndexedStack (no Scaffold/AppBar of its own), so a
              // bare push leaves the page with no back button.
              Future.microtask(() {
                if (!mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text(AppLocalizations.of(context).navSettings)),
                      body: const SettingsScreen(),
                    ),
                  ),
                );
              });
            },
            child: Text(AppLocalizations.of(context).tmdbOpenSettings),
          ),
        ],
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    widget.refreshTick?.removeListener(_loadLibrary);
    ContinueWatchingStore.changes.removeListener(_loadLibrary);
    LibraryFoldersStore.changes.removeListener(_loadLibrary);
    TmdService.instance.removeListener(_onMetadataChanged);
    DownloadManager.instance.removeListener(_onMetadataChanged);
    DownloadManager.instance.onNotificationTap = null;
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  /// A route pushed above Home popped (file browser, player, "Open with"), so
  /// resume positions may have changed — refresh the continue-watching list.
  @override
  void didPopNext() {
    _loadLibrary();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The list may have changed while the app was in the background (e.g. the
    // player paused and saved a resume position), so refresh on return.
    if (state == AppLifecycleState.resumed) {
      _loadLibrary();
    }
  }

  Future<void> _loadLibrary() async {
    final entries = await ContinueWatchingStore.load();
    _loadLibraryFolders();
    if (mounted) {
      setState(() => _entries = entries);
    }
    _resolveMetadata(entries);
  }

  /// Loads the "Your library" folder list, then kicks off best-effort TMDB
  /// lookups so each folder card can show the show's poster.
  Future<void> _loadLibraryFolders() async {
    final folders = await LibraryFoldersStore.load();
    final metas = await _client.loadAllFolderMeta();
    final groups = const SeriesGroupingService().group(folders);
    if (mounted) {
      setState(() {
        _folders = folders;
        _seriesGroups = groups;
        _jellyfinMeta = metas;
      });
    }
    _resolveFolderMetadata(folders);
    _refreshJellyfinMeta(folders);
  }

  /// Pull-to-refresh handler: reloads the whole home surface from scratch —
  /// continue-watching positions, the library folders (added from SMB / WebDAV /
  /// FTP / UPnP / Jellyfin / local), their Jellyfin posters, and the TMDB
  /// metadata behind every card. Driven by the [RefreshIndicator] wrapping the
  /// home [CustomScrollView].
  Future<void> _refreshHome() async {
    final entries = await ContinueWatchingStore.load();
    if (!mounted) return;
    setState(() => _entries = entries);
    final folders = await LibraryFoldersStore.load();
    if (!mounted) return;
    final groups = const SeriesGroupingService().group(folders);
    setState(() {
      _folders = folders;
      _seriesGroups = groups;
    });
    await _resolveFolderMetadata(folders);
    await _refreshJellyfinMeta(folders);
  }

  /// Best-effort server-side metadata for the Jellyfin library folders: any
  /// folder with no cached entry gets its info fetched from the server (the
  /// bookmark flow already saves it, so this only fills gaps).
  Future<void> _refreshJellyfinMeta(List<LibraryFolder> folders) async {
    for (final folder in folders) {
      if (!folder.isJellyfin || _jellyfinMeta.containsKey(folder.id)) continue;
      final itemId = folder.jellyfinItemId;
      if (itemId == null || itemId.isEmpty) continue;
      try {
        final server = await _client.serverForUrl(
          folder.jellyfinServerUrl ?? '',
        );
        if (server == null || !server.isAuthenticated) continue;
        final info = await _client.getPrimaryPosterInfo(server, itemId);
        if (info == null) continue;
        await _client.saveFolderMeta(folder.id, info);
        if (mounted) {
          setState(() {
            _jellyfinMeta = {..._jellyfinMeta, folder.id: info};
          });
        }
      } catch (_) {
        // Best-effort — the card falls back to the folder name / TMDB lookup.
      }
    }
  }

  Future<void> _resolveFolderMetadata(List<LibraryFolder> folders) async {
    final service = TmdService.instance;
    await service.ensureLoaded();
    for (final folder in folders) {
      final key = folder.metadataKey;
      final existing = service.metaFor(key);
      if (existing == null || existing.folderSeason == null) {
        try {
          await service.resolveFolder(
            key,
            folder.name,
            yearHint: folder.yearHint,
          );
        } catch (_) {
          // Network failures are non-fatal; the card stays a placeholder.
          continue;
        }
      }
      // Fetch season data so the season poster is available for the card.
      final meta = service.metaFor(key);
      if (meta != null && meta.folderSeason != null && meta.movie.kind == TmdKind.tv) {
        try {
          await service.seasonFor(key, meta.folderSeason!);
        } catch (_) {}
      }
      // Pull the full details (backdrop/overview/cast) right away so the
      // folder's details screen is complete the moment it's opened — metadata
      // is fetched when the folder is added, not when it's opened.
      try {
        await service.detailsFor(key);
      } catch (_) {}
    }
  }

  /// Presents the system folder picker and adds the picked folder to the
  /// library. The folder becomes a card on home only — it is stored under its
  /// own library bookmark, so it never shows up as an Internal-storage root;
  /// its videos stay in place.
  Future<void> _addFolderToLibrary() async {
    final FileEntry? picked;
    try {
      picked = await FileBrowserService.instance
          .pickLibraryFolder()
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The folder picker timed out. Please try again.',
          ),
        ),
      );
      return;
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? AppLocalizations.of(context).homeCouldNotPickFolder)),
      );
      return;
    }
    if (picked == null || !mounted) return;

    // List children to decide: expand or add as a single card.
    List<FileEntry> children = const [];
    try {
      children = await FileBrowserService.instance
          .listDirectory(picked.path)
          .timeout(const Duration(seconds: 15));
    } catch (_) {}

    // Check auto-expand pref.
    final prefs = await SharedPreferences.getInstance();
    final autoExpand = prefs.getBool('dreamplayer.autoExpandFolders') ?? true;

    if (autoExpand && children.isNotEmpty) {
      // Expand: create one LibraryFolder per child (directories + video files).
      final parentId = picked.bookmarkId ?? 'folder_${DateTime.now().millisecondsSinceEpoch}';
      final expanded = <LibraryFolder>[];
      for (final child in children) {
        final childId = '${parentId}_${child.name.hashCode}';
        if (child.isDirectory) {
          int? childYearHint;
          try {
            final grandChildren = await FileBrowserService.instance
                .listDirectory(child.path)
                .timeout(const Duration(seconds: 10));
            childYearHint = ParsedFileName.yearFromNames(
              grandChildren.where((e) => !e.isDirectory).map((e) => e.name),
            );
          } catch (_) {}
          expanded.add(LibraryFolder(
            id: childId,
            name: child.name,
            path: child.path,
            addedAt: DateTime.now(),
            parentId: parentId,
            yearHint: childYearHint,
          ));
        } else if (_isVideoFile(child.name)) {
          expanded.add(LibraryFolder(
            id: childId,
            name: child.name,
            path: child.path,
            addedAt: DateTime.now(),
            source: LibraryFolderSource.files,
            parentId: parentId,
            isFile: true,
            videoPath: child.path,
            videoSizeBytes: child.size > 0 ? child.size : null,
          ));
        }
      }
      if (expanded.isNotEmpty) {
        await LibraryFoldersStore.bulkAdd(expanded);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${picked.name}" expanded into ${expanded.length} items')),
        );
        _resolveFolderMetadata(expanded.where((f) => !f.isFile).toList());
        return;
      }
    }

    // Fallback: add as a single card (current behavior).
    int? yearHint;
    try {
      yearHint = ParsedFileName.yearFromNames(
        children.where((e) => !e.isDirectory).map((e) => e.name),
      );
    } catch (_) {}
    final folder = LibraryFolder(
      id: picked.bookmarkId ?? 'folder_${DateTime.now().millisecondsSinceEpoch}',
      name: picked.name,
      path: picked.path,
      addedAt: DateTime.now(),
      yearHint: yearHint,
    );
    await LibraryFoldersStore.add(folder);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${picked.name}" added to your library')),
    );
    _resolveFolderMetadata([folder]);
  }

  /// Quick check: does the filename look like a video file?
  static bool _isVideoFile(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.mkv') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.m2ts') ||
        lower.endsWith('.wmv') ||
        lower.endsWith('.flv') ||
        lower.endsWith('.ogv') ||
        lower.endsWith('.rmvb') ||
        lower.endsWith('.mpg') ||
        lower.endsWith('.mpeg') ||
        lower.endsWith('.vob') ||
        lower.endsWith('.3gp');
  }

  /// Builds a playable [VideoItem] for an auto-expanded network FILE card on
  /// the home grid. Local (`files`) cards carry path/uri directly; network
  /// cards store only ids/paths, so the source must be re-resolved live
  /// (SMB needs a fresh loopback/proxy token, WebDAV needs auth, UPnP keeps
  /// the stored raw URL, FTP is iOS-only and picks ftp:// vs sftp://).
  /// Opens a grouped series (`Strike the Blood`, `Strike the Blood II`, etc
  /// collapsed into one card). Always opens [SeriesSeasonsScreen] for the
  /// Nova-style season poster grid UI.
  void _openGroup(SeriesGroup group) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SeriesSeasonsScreen(group: group),
      ),
    );
  }

  Future<void> _removeFolder(LibraryFolder folder) async {
    // Find the group this folder belongs to (if any) so we can remove the
    // whole series at once (e.g. Strike the Blood + all its seasons).
    final group = _seriesGroups.firstWhere(
      (g) => g.folders.any((f) => f.id == folder.id),
      orElse: () => SeriesGroup(
            baseName: '',
            displayName: folder.name,
            folders: [folder],
          ),
    );
    final isGroup = group.folders.length > 1 ||
        (group.folders.length == 1 &&
            group.folders.first.id == folder.id &&
            _seriesGroups.any((g) => g.folders.any((f) => f.id == folder.id)));
    final foldersToRemove = isGroup ? group.folders : [folder];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context).homeRemoveFromLibrary),
        content: Text(
          isGroup
              ? '"${group.displayName}" and all its seasons will no longer '
                'appear here. The files stay on your device.'
              : '"${folder.name}" will no longer appear here. '
                'The files stay on your device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(AppLocalizations.of(context).commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(AppLocalizations.of(context).commonRemove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    for (final f in foldersToRemove) {
      await LibraryFoldersStore.remove(f.id);
      if (f.source == LibraryFolderSource.files) {
        try {
          await FileBrowserService.instance.removeLibraryBookmark(f.id);
        } catch (_) {}
      } else if (f.isJellyfin) {
        try {
          await _client.removeFolderMeta(f.id);
        } catch (_) {}
      }
      try {
        await TmdService.instance.clear(f.metadataKey);
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _folders = _folders
          .where((f) => !foldersToRemove.any((r) => r.id == f.id))
          .toList();
    });
  }

  /// Best-effort TMDB lookups so cards can show poster art and real titles
  /// without waiting for a tap.
  Future<void> _resolveMetadata(List<ContinueWatchingEntry> entries) async {
    final service = TmdService.instance;
    await service.ensureLoaded();
    for (final e in entries) {
      final video = e.video;
      final key = TmdStore.identityKeyFor(video);
      if (service.metaFor(key) != null) continue;
      try {
        await service.resolve(video);
      } catch (_) {
        // Network failures are non-fatal; the card just stays a placeholder.
      }
    }
  }

  Future<void> _removeVideo(ContinueWatchingEntry entry) async {
    final video = entry.video;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context).homeRemoveFromContinue),
        content: Text('"${video.title}" will no longer appear here.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(AppLocalizations.of(context).commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(AppLocalizations.of(context).commonRemove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final key = ContinueWatchingStore.keyFor(video);
    await ContinueWatchingStore.remove(key);
    if (!mounted) return;
    setState(() {
      _entries = _entries
          .where((e) => ContinueWatchingStore.keyFor(e.video) != key)
          .toList();
    });
  }

  void _openVideo(ContinueWatchingEntry entry) async {
    // iOS: re-grant security-scoped access to the picked file if it's outside
    // the sandbox (the picker's grant expires between launches). Covers both
    // per-file imported videos and files inside bookmarked folders.
    if (entry.video.path != null) {
      await FileBrowserService.instance.resolvePath(entry.video.path!);
    }
    if (!mounted) return;
    var video = await _restoreWebDavSource(entry.video);
    if (!mounted) return;
    final restored = await _restoreJellyfinSource(video);
    if (!mounted) return;
    // Open the details page first; Play launches the player from there.
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(video: restored),
      ),
    );
    // Resume positions may have changed while playing — refresh on return.
    await _loadLibrary();
    // Scroll back to the top so the app-bar title and section heading are
    // visible (the watched card moves to index 0 after the list reorders,
    // which would otherwise leave the viewport stranded mid-list).
    if (mounted && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  /// Groups continue-watching entries by TV show (via TMDB show ID) so
  /// episodes from the same series appear as a single card. Non-episode
  /// entries (movies, standalone videos) pass through ungrouped.
  List<_GroupedContinueWatching> _groupedByShow(
    List<ContinueWatchingEntry> entries,
  ) {
    final service = TmdService.instance;
    final List<_GroupedContinueWatching> result = [];

    for (final entry in entries) {
      final video = entry.video;
      final parsed = ParsedFileName.parse(video.title);
      String? showId;
      if (parsed.isEpisode) {
        final key = TmdStore.identityKeyFor(video);
        final meta = service.metaFor(key);
        showId = meta?.movie.id.toString();
      }
      // Each episode gets its own card — no series grouping.
      result.add(_GroupedContinueWatching(
        showTitle: video.title,
        showMeta: showId != null
            ? service.metaFor(TmdStore.identityKeyFor(video))
            : null,
        entries: [entry],
      ));
    }

    return result;
  }

  /// WebDAV entries deliberately do NOT persist the Authorization header (no
  /// plaintext credentials). The saved key encodes the server id + path, so
  /// rebuild the source with a freshly-fetched header and the server's current
  /// URL when the user taps a continue-watching card.
  Future<VideoItem> _restoreWebDavSource(VideoItem video) async {
    final key = video.resumeKey;
    if (key == null || !key.startsWith('webdav_')) return video;
    final rest = key.substring('webdav_'.length);
    // Server id = leading UUID (or legacy integer id), the rest is the path.
    final id =
        RegExp(
          '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}',
        ).firstMatch(rest)?.group(0) ??
        RegExp(r'^\d+').firstMatch(rest)?.group(0);
    if (id == null || rest.length <= id.length) return video;
    try {
      final servers = await WebDavClient.instance.listServers();
      WebDavServer? server;
      for (final s in servers) {
        if (s.id == id) {
          server = s;
          break;
        }
      }
      if (server == null) return video;
      var auth = '';
      try {
        auth = await WebDavClient.instance.authorizationHeader(id);
      } on PlatformException {
        auth = '';
      }
      final path = rest.substring(id.length);
      final base = server.url.replaceAll(RegExp(r'/+$'), '');
      return VideoItem(
        id: video.id,
        title: video.title,
        uri: '$base${_encodePath(path)}',
        resumeKey: key,
        duration: video.duration,
        sizeBytes: video.sizeBytes,
        httpHeaders: auth.isEmpty ? const {} : {'Authorization': auth},
        allowSelfSigned: server.allowSelfSigned,
        videoCodec: video.videoCodec,
        audioCodec: video.audioCodec,
        audioChannels: video.audioChannels,
        resolution: video.resolution,
        hdrHint: video.hdrHint,
      );
    } on PlatformException {
      return video;
    }
  }

  /// Jellyfin stream URLs embed the session's `api_key`, which rotates on
  /// re-login. Rebuild the URL from the stable resume key
  /// (`jellyfin:<host>/<item>`) against the current saved server + token.
  Future<VideoItem> _restoreJellyfinSource(VideoItem video) async {
    final key = video.resumeKey;
    if (key == null || !key.startsWith('jellyfin:')) return video;
    final rest = key.substring('jellyfin:'.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return video;
    final host = rest.substring(0, slash);
    final itemId = rest.substring(slash + 1);
    if (host.isEmpty || itemId.isEmpty) return video;
    final servers = await _client.loadServers();
    JellyfinServer? server;
    for (final s in servers) {
      if (s.urlHost == host) {
        server = s;
        break;
      }
    }
    if (server == null || !server.isAuthenticated) return video;
    final item = JellyfinItem(id: itemId, name: video.title);
    // Refresh stale api_key in persisted external subtitle URLs (token rotates).
    final refreshedSubs = video.externalSubtitles.map((s) {
      var u = s.uri;
      if (u.contains('api_key=')) {
        u = u.replaceAll(
          RegExp(r'api_key=[^&]*'),
          'api_key=${server!.token ?? ''}',
        );
      }
      return VideoExternalSub(
        uri: u,
        label: s.label,
        language: s.language,
        mimeType: s.mimeType,
        isDefault: s.isDefault,
      );
    }).toList();
    return VideoItem(
      id: video.id,
      title: video.title,
      uri: _client.streamUrl(server, item),
      resumeKey: key,
      duration: video.duration,
      sizeBytes: video.sizeBytes,
      allowSelfSigned: server.allowSelfSigned,
      jellyfinServerId: server.urlHost,
      jellyfinItemId: itemId,
      externalSubtitles: refreshedSubs,
      videoCodec: video.videoCodec,
      audioCodec: video.audioCodec,
      audioChannels: video.audioChannels,
      resolution: video.resolution,
      hdrHint: video.hdrHint,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tv = isTvMode(context);
    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildDrawer(theme),
      body: TvOverscan(
        child: RefreshIndicator(
          onRefresh: _refreshHome,
          // Pull down on the home list (from SMB / WebDAV / local / Jellyfin /
          // any source) to reload the library — re-digit the persisted folders,
          // their Jellyfin posters, continue-watching positions, and the TMDB
          // metadata for every card.
          edgeOffset: 8,
          child: CustomScrollView(
            controller: _scrollController,
            // Always scrollable so pull-to-refresh works even when the content
            // doesn't fill the screen (e.g. an empty library).
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
            SliverAppBar(
              leading: Builder(
                builder: (ctx) => IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                ),
              ),
              title: Text(AppLocalizations.of(context).homeTitle),
              pinned: true,
            ),
            // ---- Your library: user-added folders (e.g. TV-show folders) ----
            if (_seriesGroups.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text(
                    tv
                        ? 'No folders yet. Use the buttons above to add one.'
                        : 'No folders yet. Tap + to add one.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    AppLocalizations.of(context).homeYourLibrary,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              _folderGridSliver(
                count: _seriesGroups.length,
                itemBuilder: (context, index) {
                  final group = _seriesGroups[index];
                  return FolderCard(
                    key: ValueKey(group.metadataKey),
                    folder: group.primary,
                    tmdbMeta: TmdService.instance.metaFor(group.metadataKey),
                    jellyfinInfo: _jellyfinMeta[group.primary.id],
                    groupCount: group.folders.length,
                    onTap: () => _openGroup(group),
                    onLongPress: () => _removeFolder(group.primary),
                  );
                },
              ),
            ],
            // ---- Downloaded videos ----
            if (_downloadedJobs.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    AppLocalizations.of(context).homeDownloaded,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              _buildDownloadedGrid(theme),
            ],
            // ---- Continue watching ----
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Text(
                  AppLocalizations.of(context).homeContinueWatching,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (_entries.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyLibrary(),
              )
            else
              _buildContinueWatchingGrid(theme),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddMenu,
        tooltip: 'Add a source',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildDrawer(ThemeData theme) {
    final mgr = DownloadManager.instance;
    final active = mgr.downloads
        .where((j) => j.status == DownloadStatus.downloading ||
            j.status == DownloadStatus.queued)
        .toList();
    final completed = mgr.downloads
        .where((j) => j.status == DownloadStatus.completed)
        .toList();
    final failed = mgr.downloads
        .where((j) => j.status == DownloadStatus.failed ||
            j.status == DownloadStatus.cancelled)
        .toList();
    return Drawer(
      backgroundColor: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'DreamPlayer',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Divider(height: 1),
            // Active downloads section.
            if (active.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text(
                      AppLocalizations.of(context).homeDownloading,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              ...active.map((job) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: ListTile(
                  dense: true,
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.downloading, color: Colors.blue, size: 20),
                  ),
                  title: Text(
                    job.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  subtitle: job.totalBytes > 0
                      ? Text(
                          '${job.downloadedLabel} / ${job.fileSizeLabel}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        )
                      : Text(
                          '${job.downloadedLabel} downloaded',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                    onPressed: () => mgr.cancelDownload(job.id),
                  ),
                ),
              )),
              const Divider(height: 1),
            ],
            // Completed downloads section.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                AppLocalizations.of(context).homeDownloads,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (completed.isEmpty && active.isEmpty && failed.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                child: Text(
                  AppLocalizations.of(context).homeNoDownloads,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else if (completed.isEmpty && failed.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text(
                  AppLocalizations.of(context).homeNoCompletedDownloads,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    // Completed downloads.
                    ...completed.map((job) => ListTile(
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.check_circle, color: Colors.green, size: 20),
                      ),
                      title: Text(
                        job.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      subtitle: Text(
                        job.fileSizeLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.delete_outline, color: theme.colorScheme.onSurfaceVariant, size: 20),
                        onPressed: () => _confirmDeleteDownload(job),
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _playDownload(job);
                      },
                    )),
                    // Failed / cancelled downloads.
                    ...failed.map((job) => ListTile(
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          job.status == DownloadStatus.cancelled
                              ? Icons.cancel
                              : Icons.error,
                          color: Colors.orange,
                          size: 20,
                        ),
                      ),
                      title: Text(
                        job.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      subtitle: Text(
                        job.status == DownloadStatus.cancelled ? AppLocalizations.of(context).homeCancelled : AppLocalizations.of(context).homeFailed,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.orange,
                        ),
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.delete_outline, color: theme.colorScheme.onSurfaceVariant, size: 20),
                        onPressed: () => mgr.deleteDownload(job.id),
                      ),
                    )),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _openDownloadsDrawer() {
    if (mounted) _scaffoldKey.currentState?.openDrawer();
  }

  void _playDownload(DownloadJob job) {
    if (!File(job.destPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File not found — it may have been deleted.'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          video: VideoItem(
            id: job.id,
            title: job.title,
            path: job.destPath,
            duration: Duration.zero,
            sizeBytes: job.totalBytes > 0 ? job.totalBytes : null,
          ),
        ),
      ),
    );
  }

  void _confirmDeleteDownload(DownloadJob job) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: theme.colorScheme.surface,
        title: Text(AppLocalizations.of(context).homeRemoveDownload),
        content: Text(
          AppLocalizations.of(context).downloadDeleteConfirm(job.title),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.of(context).commonCancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              DownloadManager.instance.deleteDownload(job.id);
            },
            child: Text(AppLocalizations.of(context).commonDelete),
          ),
        ],
      ),
    );
  }

  /// Completed downloads whose local files still exist on disk.
  List<DownloadJob> get _downloadedJobs => DownloadManager.instance.downloads
      .where((j) => j.status == DownloadStatus.completed && File(j.destPath).existsSync())
      .toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  Widget _buildDownloadedGrid(ThemeData theme) {
    final jobs = _downloadedJobs;
    return _videoGridSliver(
      count: jobs.length,
      itemBuilder: (context, index) {
        final job = jobs[index];
        final video = VideoItem(
          id: job.id,
          title: job.title,
          path: job.destPath,
          duration: Duration.zero,
          sizeBytes: job.totalBytes > 0 ? job.totalBytes : null,
        );
        return VideoCard(
          key: ValueKey('dl_${job.id}'),
          video: video,
          subtitle: job.fileSizeLabel,
          downloaded: true,
          onTap: () => _playDownloaded(job),
          onLongPress: () => _confirmDeleteDownload(job),
        );
      },
    );
  }

  void _playDownloaded(DownloadJob job) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          video: VideoItem(
            id: job.id,
            title: job.title,
            path: job.destPath,
            duration: Duration.zero,
            sizeBytes: job.totalBytes > 0 ? job.totalBytes : null,
          ),
        ),
      ),
    );
  }

  /// A responsive grid of video cards (columns from the screen width), shared
  /// by the "Continue watching" and "Downloaded" sections.
  Widget _videoGridSliver({
    required int count,
    required Widget Function(BuildContext, int) itemBuilder,
  }) {
    return SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          final columns = _columnsForWidth(width);
          const spacing = 14.0;
          final itemWidth = (width - spacing * (columns - 1)) / columns;
          final itemHeight = itemWidth * 9 / 16 + _textBlockHeight;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              mainAxisExtent: itemHeight,
            ),
            delegate: SliverChildBuilderDelegate(
              itemBuilder,
              childCount: count,
            ),
          );
        },
      ),
    );
  }

  /// Builds the continue-watching grid, grouping TV episodes by show
  /// (Nova-style). Movies and standalone videos pass through ungrouped.
  Widget _buildContinueWatchingGrid(ThemeData theme) {
    final grouped = _groupedByShow(_entries);
    return _videoGridSliver(
      count: grouped.length,
      itemBuilder: (context, index) {
        final group = grouped[index];
        if (group.isSeries) {
          // TV show card: show poster + latest episode info.
          final entry = group.mostRecent;
          final video = entry.video;
          final progress = video.duration > Duration.zero
              ? (entry.position.inMilliseconds /
                        video.duration.inMilliseconds)
                    .clamp(0.0, 1.0)
              : null;
          return VideoCard(
            key: ValueKey(video.resumeKey ?? video.uri ?? video.title),
            video: video,
            tmdbMeta: group.showMeta,
            progress: progress,
            subtitle: group.cardSubtitle(_positionLabel),
            onTap: () => _openVideo(entry),
            onLongPress: () => _removeVideo(entry),
          );
        }
        // Single entry (movie or unmatched episode).
        final entry = group.entries.first;
        final video = entry.video;
        final progress = video.duration > Duration.zero
            ? (entry.position.inMilliseconds /
                      video.duration.inMilliseconds)
                  .clamp(0.0, 1.0)
            : null;
        final parsed = ParsedFileName.parse(video.title);
        final continueLabel =
            'Continue from ${_positionLabel(entry.position)}';
        return VideoCard(
          key: ValueKey(video.resumeKey ?? video.uri ?? video.title),
          video: video,
          tmdbMeta: TmdService.instance.metaFor(
            TmdStore.identityKeyFor(video),
          ),
          progress: progress,
          subtitle: parsed.isEpisode
              ? '${parsed.episodeLabel} · $continueLabel'
              : continueLabel,
          onTap: () => _openVideo(entry),
          onLongPress: () => _removeVideo(entry),
        );
      },
    );
  }

  /// A responsive grid of folder cards with poster-sized cells (2:3).
  Widget _folderGridSliver({
    required int count,
    required Widget Function(BuildContext, int) itemBuilder,
  }) {
    return SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          final columns = _columnsForWidth(width);
          const spacing = 14.0;
          final itemWidth = (width - spacing * (columns - 1)) / columns;
          final itemHeight = itemWidth * 3 / 2 + _textBlockHeight;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              mainAxisExtent: itemHeight,
            ),
            delegate: SliverChildBuilderDelegate(
              itemBuilder,
              childCount: count,
            ),
          );
        },
      ),
    );
  }

  /// Opens the "+" menu: network sources in a collapsed section, local below.
  Future<void> _showAddMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Local actions (always visible) ──
                ListTile(
                  leading: const Icon(Icons.video_library_outlined),
                  title: Text(AppLocalizations.of(context).homeAddFolder),
                  subtitle: Text(
                    'A TV-show folder, a movie folder\u2026',
                  ),
                  onTap: () => Navigator.of(context).pop('add-folder'),
                ),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: Text(AppLocalizations.of(context).homeInternalStorage),
                  subtitle: Text(AppLocalizations.of(context).homeBrowseFiles),
                  onTap: () => Navigator.of(context).pop('storage'),
                ),
                const Divider(height: 1),
                // ── Network sources (collapsed section) ──
                ExpansionTile(
                  leading: const Icon(Icons.wifi_outlined),
                  title: Text(AppLocalizations.of(context).homeNetworkSources),
                  subtitle: Text(AppLocalizations.of(context).upnpOnThisNetwork),
                  children: [
                    ListTile(
                      leading: const Icon(Icons.folder_shared_outlined),
                      title: Text(AppLocalizations.of(context).homeSmbNas),
                      subtitle: Text(
                        Platform.isAndroid
                            ? AppLocalizations.of(context).homeSmbLocalShares
                            : AppLocalizations.of(context).homeSmbViaFilesApp,
                      ),
                      onTap: () => Navigator.of(context).pop(
                        Platform.isAndroid ? 'smb' : 'smb-ios',
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.cloud_outlined),
                      title: Text('WebDAV'),
                      subtitle: Text(AppLocalizations.of(context).homeAddWebdavServer),
                      onTap: () => Navigator.of(context).pop('webdav'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text('FTP / SFTP'),
                      subtitle: Text(AppLocalizations.of(context).homeFtpOrSftp),
                      onTap: () => Navigator.of(context).pop('ftp'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.live_tv_outlined),
                      title: Text('Jellyfin'),
                      subtitle: Text(AppLocalizations.of(context).homeJellyfinServer),
                      onTap: () => Navigator.of(context).pop('jellyfin'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.cast_connected_outlined),
                      title: Text('DLNA'),
                      subtitle: Text(AppLocalizations.of(context).homeUpnpDlna),
                      onTap: () => Navigator.of(context).pop('upnp'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.link_outlined),
                      title: Text(AppLocalizations.of(context).homePlayUrl),
                      subtitle: Text(AppLocalizations.of(context).homeStreamLink),
                      onTap: () => Navigator.of(context).pop('play-url'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == null) return;
    await _openSource(action);
  }

  /// Navigates to the given source (menu action string). Shared by the "+"
  /// menu and the TV-mode app-bar buttons.
  Future<void> _openSource(String action) async {
    switch (action) {
      case 'webdav':
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const WebDavScreen()));
      case 'ftp':
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const FtpScreen()));
      case 'jellyfin':
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const JellyfinScreen()));
      case 'smb':
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SmbScreen()));
        break;
      case 'smb-ios':
        // iOS: SMB goes through the Files app. Picking a folder from the
        // system document picker (which lists Files-app "Connect to Server"
        // shares) bookmarks it as a library folder, so the share shows up on
        // the home grid with a TMDB poster and is browsable/playable.
        await _addFolderToLibrary();
        break;
      case 'upnp':
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const UpnpScreen()));
        break;
      case 'storage':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const FileBrowserScreen()),
        );
      case 'play-url':
        await _playUrlDialog();
      case 'add-folder':
        await _addFolderToLibrary();
    }
  }

  /// Asks for a direct video URL and plays it. The URL is its own stable
  /// resume key, so re-entering the same link continues where it stopped.
  Future<void> _playUrlDialog() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppLocalizations.of(context).homePlayUrl),
        content: TvTextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: 'https://example.com/video.mp4',
            labelText: AppLocalizations.of(context).homeVideoUrl,
          ),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(AppLocalizations.of(context).detailsPlay),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid http(s) URL')),
      );
      return;
    }
    final last = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    final title = Uri.decodeComponent(last.isNotEmpty ? last : uri.host);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          video: () {
            final fi = extractFileInfo(title);
            return VideoItem(
              id: 'url_${url.hashCode}',
              title: title,
              uri: url,
              resumeKey: 'url:$url',
              duration: Duration.zero,
              videoCodec: fi.videoCodec,
              audioCodec: fi.audioCodec,
              audioChannels: fi.audioChannels,
              resolution: fi.resolution,
              hdrHint: fi.hdrHint,
            );
          }(),
        ),
      ),
    );
  }

  static int _columnsForWidth(double width) {
    if (width >= 1000) return 6;
    if (width >= 760) return 4;
    if (width >= 480) return 3;
    return 2;
  }

  /// Percent-encodes each path segment (mirrors `_encodePath` in
  /// `webdav_screen.dart`).
  static String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  static String _positionLabel(Duration position) {
    final h = position.inHours;
    final m = position.inMinutes.remainder(60);
    final s = position.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static const double _textBlockHeight = 84;
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 72,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            SizedBox(height: 16),
            Text(
              AppLocalizations.of(context).homeNothingYet,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Videos you play will appear here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A grouped continue-watching entry: either a single video (movie/standalone)
/// or a TV show with multiple episode entries clustered together.
class _GroupedContinueWatching {
  _GroupedContinueWatching({
    required this.showTitle,
    required this.showMeta,
    required this.entries,
  });

  final String showTitle;
  final TmdMeta? showMeta;
  final List<ContinueWatchingEntry> entries;

  /// Whether this represents a TV show with multiple episodes.
  bool get isSeries => entries.length > 1;

  /// The most recently played entry (first in the list after sorting).
  ContinueWatchingEntry get mostRecent => entries.first;

  /// The show's poster URL for the card image.
  String? get posterUrl => showMeta?.movie.posterUrl();

  /// The show's backdrop URL for the card image.
  String? get backdropUrl => showMeta?.movie.backdropUrl();

  /// Subtitle for the card: "S01E03 · Continue from 12:34" or just
  /// "Continue from 12:34" for a single entry.
  String cardSubtitle(String Function(Duration) positionLabel) {
    final entry = mostRecent;
    final parsed = ParsedFileName.parse(entry.video.title);
    final continueLabel = 'Continue from ${positionLabel(entry.position)}';
    if (isSeries) {
      final epLabel = parsed.isEpisode ? parsed.episodeLabel : '';
      return epLabel.isNotEmpty ? '$epLabel · $continueLabel' : continueLabel;
    }
    return continueLabel;
  }
}
