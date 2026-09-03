import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart' show appRouteObserver;
import '../models/video_item.dart';
import '../services/continue_watching.dart';
import '../services/file_browser.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/tmdb_client.dart';
import '../services/webdav_client.dart';
import '../widgets/folder_card.dart';
import '../widgets/tv_text_field.dart';
import 'ftp_screen.dart';
import 'player_screen.dart';
import 'settings_screen.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/video_card.dart';
import '../utils/tv_helper.dart';
import 'file_browser_screen.dart';
import 'jellyfin_screen.dart';
import '../utils/file_info_extractor.dart';
import '../utils/startup_permissions.dart';
import 'smb_screen.dart';
import 'folder_screen.dart';
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
  List<ContinueWatchingEntry> _entries = const [];

  /// "Your library": the folders the user added (e.g. TV-show folders), most
  /// recently added first. Nothing is auto-scanned — only these appear.
  List<LibraryFolder> _folders = const [];

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
        title: const Text('Enable movie details?'),
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
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () async {
                // Call launchUrl directly (no canLaunchUrl gate) — matches
                // openSupportUrl. canLaunchUrl returns false on Android 11+
                // for https VIEW intents and would silently swallow the tap.
                final uri = Uri.parse('https://www.themoviedb.org/settings/api');
                try {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } catch (_) {}
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Get a free TMDB API key'),
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
            child: const Text('Close'),
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
                      appBar: AppBar(title: const Text('Settings')),
                      body: const SettingsScreen(),
                    ),
                  ),
                );
              });
            },
            child: const Text('Open Settings'),
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
    if (mounted) {
      setState(() {
        _folders = folders;
        _jellyfinMeta = metas;
      });
    }
    _resolveFolderMetadata(folders);
    _refreshJellyfinMeta(folders);
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
      if (service.metaFor(key) == null) {
        try {
          await service.resolveFolder(key, folder.name);
        } catch (_) {
          // Network failures are non-fatal; the card stays a placeholder.
          continue;
        }
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
        SnackBar(content: Text(e.message ?? 'Could not pick a folder')),
      );
      return;
    }
    if (picked == null || !mounted) return;
    final folder = LibraryFolder(
      id:
          picked.bookmarkId ??
          'folder_${DateTime.now().millisecondsSinceEpoch}',
      name: picked.name,
      path: picked.path,
      addedAt: DateTime.now(),
    );
    await LibraryFoldersStore.add(folder);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${picked.name}" added to your library')),
    );
    // TMDB poster for the new card resolves in the background.
    _resolveFolderMetadata([folder]);
  }

  /// Opens a library folder: the show/movie details screen with the folder's
  /// files (episodes) listed below it.
  void _openFolder(LibraryFolder folder) async {
    // Network bookmarks (SMB/WebDAV) open the folder browser directly
    // so the file list appears immediately — TmdDetailsScreen's file list
    // only knows FileBrowser/Jellyfin.
    if (folder.source == LibraryFolderSource.smb ||
        folder.source == LibraryFolderSource.webdav ||
        folder.source == LibraryFolderSource.ftp ||
        folder.source == LibraryFolderSource.upnp) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FolderScreen(folder: folder),
        ),
      );
      await _loadLibrary();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          folder: folder,
          jellyfinInfo: _jellyfinMeta[folder.id],
        ),
      ),
    );
    await _loadLibrary();
  }

  Future<void> _removeFolder(LibraryFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from library?'),
        content: Text(
          '"${folder.name}" will no longer appear here. '
          'The files stay on your device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await LibraryFoldersStore.remove(folder.id);
    // Release the native library bookmark so its grant doesn't linger (only
    // for on-device folders — network/Jellyfin bookmarks have no native grant).
    if (folder.source == LibraryFolderSource.files) {
      try {
        await FileBrowserService.instance.removeLibraryBookmark(folder.id);
      } catch (_) {}
    } else if (folder.isJellyfin) {
      // Drop the cached server-side metadata too so a re-add re-fetches fresh.
      try {
        await _client.removeFolderMeta(folder.id);
      } catch (_) {}
    }
    // Drop the folder's TMDB metadata too so a re-add re-matches cleanly.
    try {
      await TmdService.instance.clear(folder.metadataKey);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _folders = _folders.where((f) => f.id != folder.id).toList();
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
        title: const Text('Remove from Continue watching?'),
        content: Text('"${video.title}" will no longer appear here.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
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
    final Map<String, _GroupedContinueWatching> shows = {};
    final List<_GroupedContinueWatching> result = [];

    for (final entry in entries) {
      final video = entry.video;
      final parsed = ParsedFileName.parse(video.title);
      if (parsed.isEpisode) {
        final key = TmdStore.identityKeyFor(video);
        final meta = service.metaFor(key);
        final showId = meta?.movie.id.toString();
        if (showId != null) {
          shows.putIfAbsent(
            showId,
            () => _GroupedContinueWatching(
              showTitle: meta?.movie.title ?? parsed.title,
              showMeta: meta,
              entries: [],
            ),
          );
          shows[showId]!.entries.add(entry);
          continue;
        }
      }
      // Non-episode or no TMDB match → pass through as-is.
      result.add(_GroupedContinueWatching(
        showTitle: video.title,
        showMeta: null,
        entries: [entry],
      ));
    }

    // Sort grouped shows by most-recently-played entry.
    final grouped = shows.values.toList()
      ..sort((a, b) {
        final aTime = a.entries.first.position;
        final bTime = b.entries.first.position;
        return bTime.compareTo(aTime);
      });

    result.insertAll(0, grouped);
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
      body: TvOverscan(
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverAppBar(title: const Text('DreamPlayer'), pinned: true),
            // ---- Your library: user-added folders (e.g. TV-show folders) ----
            if (_folders.isEmpty)
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
                    'Your library',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              _folderGridSliver(
                count: _folders.length,
                itemBuilder: (context, index) {
                  final folder = _folders[index];
                  return FolderCard(
                    key: ValueKey(folder.id),
                    folder: folder,
                    tmdbMeta: TmdService.instance.metaFor(folder.metadataKey),
                    jellyfinInfo: _jellyfinMeta[folder.id],
                    onTap: () => _openFolder(folder),
                    onLongPress: () => _removeFolder(folder),
                  );
                },
              ),
            ],
            // ---- Continue watching ----
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Text(
                  'Continue watching',
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
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddMenu,
        tooltip: 'Add a source',
        child: const Icon(Icons.add),
      ),
    );
  }

  /// A responsive grid of video cards (columns from the screen width), shared
  /// by the "Continue watching" section.
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

  /// Opens the "+" menu: WebDAV server, internal storage, add folder, Jellyfin.
  Future<void> _showAddMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      // Default sheets cap at 9/16 of screen height — in phone landscape that
      // clips the tail of the list. Scroll-controlled + height-capped so all
      // entries stay reachable on any orientation.
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
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('WebDAV'),
                  subtitle: const Text('Add a WebDAV server'),
                  onTap: () => Navigator.of(context).pop('webdav'),
                ),
                // FTP/SFTP browse + playback on every platform (iOS via the
                // Network.framework FTP client / Citadel SFTP in FtpClient.swift).
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('FTP / SFTP'),
                  subtitle: const Text('FTP or SFTP file server'),
                  onTap: () => Navigator.of(context).pop('ftp'),
                ),
                ListTile(
                  leading: const Icon(Icons.live_tv_outlined),
                  title: const Text('Jellyfin'),
                  subtitle: const Text('Jellyfin / Emby media server'),
                  onTap: () => Navigator.of(context).pop('jellyfin'),
                ),
                if (Platform.isAndroid)
                  ListTile(
                    leading: const Icon(Icons.folder_shared_outlined),
                    title: const Text('Network shares'),
                    subtitle: const Text('SMB / NAS shares'),
                    onTap: () => Navigator.of(context).pop('smb'),
                  )
                else
                  ListTile(
                    leading: const Icon(Icons.folder_shared_outlined),
                    title: const Text('Network shares'),
                    subtitle: const Text('SMB via the Files app'),
                    onTap: () => Navigator.of(context).pop('smb-ios'),
                  ),
                ListTile(
                  leading: const Icon(Icons.cast_connected_outlined),
                  title: const Text('DLNA'),
                  subtitle: const Text('DLNA / UPnP servers on this network'),
                  onTap: () => Navigator.of(context).pop('upnp'),
                ),
                ListTile(
                  leading: const Icon(Icons.link_outlined),
                  title: const Text('Play URL'),
                  subtitle: const Text('Stream a direct video link'),
                  onTap: () => Navigator.of(context).pop('play-url'),
                ),
                ListTile(
                  leading: const Icon(Icons.video_library_outlined),
                  title: const Text('Add folder to library'),
                  subtitle: const Text(
                    'A TV-show folder, a movie folder\u2026',
                  ),
                  onTap: () => Navigator.of(context).pop('add-folder'),
                ),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const Text('Internal storage'),
                  subtitle: const Text('Browse files on this device'),
                  onTap: () => Navigator.of(context).pop('storage'),
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
        title: const Text('Play URL'),
        content: TvTextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: 'https://example.com/video.mp4',
            labelText: 'Video URL',
          ),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Play'),
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
            const SizedBox(height: 16),
            Text(
              'Nothing yet',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
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
