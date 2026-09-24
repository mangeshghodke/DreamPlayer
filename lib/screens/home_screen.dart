import 'dart:async';
import 'dart:io' show File, InternetAddress, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart' show appRouteObserver;
import '../l10n/app_localizations.dart';
import '../models/video_item.dart';
import '../services/continue_watching.dart';
import '../services/download_manager.dart';
import '../services/file_browser.dart';
import '../services/folder_scanner.dart';
import '../services/ftp_client.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/manual_groups.dart';
import '../services/default_engine_store.dart';
import '../services/network_video_resolver.dart';
import '../services/series_grouping.dart';
import '../services/smb_client.dart';

import '../services/entitlements.dart';
import '../services/tmdb_client.dart';
import '../services/the_tvdb_client.dart';
import 'trial_intro_screen.dart';
import '../services/upnp_client.dart';
import '../services/webdav_client.dart';
import '../widgets/folder_card.dart';
import '../widgets/group_poster_dialog.dart';
import '../widgets/tv_text_field.dart';
import 'ftp_screen.dart';
import 'player_screen.dart';
import 'series_seasons_screen.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/video_card.dart';
import '../utils/tv_helper.dart';
import 'file_browser_screen.dart';
import 'jellyfin_screen.dart';
import '../utils/file_info_extractor.dart';
import '../utils/startup_permissions.dart';
import 'smb_screen.dart';
import 'tmd_details_screen.dart';
import 'movie_group_screen.dart';
import 'upnp_screen.dart';
import 'webdav_screen.dart';

/// True under `flutter test` — skips network probes that leave pending Timers.
///
/// `bool.fromEnvironment('FLUTTER_TEST')` is false for app code compiled into
/// widget tests on this Flutter version, so detect the test binding instead.
bool get _inTests =>
    WidgetsBinding.instance.runtimeType.toString().contains('Test');

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

  /// User-made manual groups (select N cards → Group).
  List<ManualGroup> _manualGroups = const [];
  final Set<String> _selectedIds = {};
  bool get _inSelectionMode => _selectedIds.isNotEmpty;

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
      _showTrialIntroIfNeeded();
    });
  }

  void _onMetadataChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _showTrialIntroIfNeeded() async {
    final e = Entitlements.instance;
    if (!e.effectivePaywallEnabled) return;
    if (e.isEntitled) return;
    if (e.trialStartedEver) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('dreamplayer.trialIntroShown') == true) return;
    await prefs.setBool('dreamplayer.trialIntroShown', true);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TrialIntroScreen()),
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
    var folders = await LibraryFoldersStore.load();
    // Jellyfin/FTP/DLNA are now browsed directly — purge any legacy
    // bookmarked entries left over from before the removal.
    final legacy = folders.where((f) =>
        f.source == LibraryFolderSource.jellyfin ||
        f.source == LibraryFolderSource.ftp ||
        f.source == LibraryFolderSource.upnp).toList();
    if (legacy.isNotEmpty) {
      for (final f in legacy) {
        await LibraryFoldersStore.remove(f.id);
      }
      folders = folders.where((f) => !legacy.contains(f)).toList();
    }
    final metas = await _client.loadAllFolderMeta();
    final manual = await ManualGroupsStore.instance.load();
    // Prune stale manual groups (folder removed / id missing). Empty/single
    // groups are dropped — they were already a single card before.
    final aliveIds = folders.map((f) => f.id).toSet();
    final pruned = manual.where((g) {
      final alive = g.folderIds.where(aliveIds.contains).toList();
      return alive.length > 1;
    }).toList();
    // Persist pruning if anything was dropped.
    if (pruned.length != manual.length) {
      await ManualGroupsStore.instance.save(pruned);
    }
    final displayGroups = _buildDisplayGroups(folders, pruned);
    if (mounted) {
      setState(() {
        _folders = folders;
        _manualGroups = pruned;
        _seriesGroups = displayGroups;
        _jellyfinMeta = metas;
      });
    }
    _resolveFolderMetadata(folders);
    _refreshJellyfinMeta(folders);
  }

  List<SeriesGroup> _buildDisplayGroups(
      List<LibraryFolder> folders, List<ManualGroup> manual) {
    final byId = {for (final f in folders) f.id: f};
    final groupedIds = <String>{};
    final manualGroups = <SeriesGroup>[];
    for (final mg in manual) {
      final members = mg.folderIds.map((id) => byId[id]).whereType<LibraryFolder>().toList();
      if (members.length <= 1) continue;
      for (final m in members) {
        groupedIds.add(m.id);
      }
      final display = mg.name.isNotEmpty ? mg.name : members.first.name;
      manualGroups.add(SeriesGroup(
        baseName: display.toLowerCase(),
        displayName: display,
        folders: members,
      ));
    }
    final remaining = folders.where((f) => !groupedIds.contains(f.id)).toList();
    final autoGroups =
        const SeriesGroupingService().groupExplicitSeasonFolders(remaining);
    manualGroups.sort((a, b) => b.primary.addedAt.compareTo(a.primary.addedAt));
    return [...manualGroups, ...autoGroups];
  }

  bool _isManualGroup(SeriesGroup g) =>
      _manualGroups.any((mg) => mg.folderIds.length == g.folders.length && mg.folderIds.every((id) => g.folders.any((f) => f.id == id)));

  ManualGroup? _manualForGroup(SeriesGroup g) {
    for (final mg in _manualGroups) {
      if (mg.folderIds.length == g.folders.length && mg.folderIds.every((id) => g.folders.any((f) => f.id == id))) {
        return mg;
      }
    }
    return null;
  }

  /// TMDB meta shown on a group card: the user-picked manual poster first
  /// (chosen at group creation), then the primary folder's key, then any
  /// member's cached meta (a manual group of random cards should show
  /// TMDB info from whichever member has it).
  TmdMeta? _metaForGroupDisplay(SeriesGroup g) {
    final picked = _manualForGroup(g)?.posterMeta;
    if (picked != null) return picked;
    final primary = TmdService.instance.metaFor(g.metadataKey);
    if (primary != null) return primary;
    final ordered = [
      g.primary,
      ...g.folders.where((f) => f.id != g.primary.id),
    ];
    for (final f in ordered) {
      final m = TmdService.instance.metaFor(f.metadataKey);
      if (m != null) return m;
    }
    return null;
  }

  // ---- Manual-group selection helpers ----
  bool _isGroupSelected(SeriesGroup g) =>
      g.folders.every((f) => _selectedIds.contains(f.id));

  void _toggleGroupSelection(SeriesGroup g) {
    final ids = g.folders.map((f) => f.id).toList();
    final allSelected = ids.every((id) => _selectedIds.contains(id));
    setState(() {
      if (allSelected) {
        _selectedIds.removeAll(ids);
      } else {
        _selectedIds.addAll(ids);
      }
    });
  }

  void _exitSelection() => setState(() => _selectedIds.clear());

  Future<void> _groupSelected() async {
    if (_selectedIds.length < 2) return;
    final selectedFolders = _folders.where((f) => _selectedIds.contains(f.id)).toList();
    if (selectedFolders.length < 2) return;
    final defaultName = _deriveGroupName(selectedFolders);
    final name = await _promptGroupName(defaultName);
    if (name == null || name.trim().isEmpty) return;
    // Optional TMDB poster picker — the user can pick a poster for the group
    // (or skip and fall back to any member's cached meta).
    final posterMeta = await _pickGroupPoster(name.trim());
    final mg = ManualGroup(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name.trim(),
      folderIds: selectedFolders.map((f) => f.id).toList(),
      posterMeta: posterMeta,
    );
    final next = [..._manualGroups, mg];
    await ManualGroupsStore.instance.save(next);
    _selectedIds.clear();
    await _loadLibraryFolders();
  }

  /// Optional poster picker for a manual group: a TMDB search dialog
  /// (query prefilled with the group name, Movie/TV toggle). Returns the
  /// picked [TmdMeta], or null when the user skips/cancels.
  Future<TmdMeta?> _pickGroupPoster(String initialQuery) {
    return showDialog<TmdMeta>(
      context: context,
      builder: (_) => GroupPosterDialog(initialQuery: initialQuery),
    );
  }

  String _deriveGroupName(List<LibraryFolder> folders) {
    // Strip bracket tags and trailing part numbers from the first name.
    var raw = folders.first.name.replaceAll(RegExp(r'\[.*?\]'), ' ');
    raw = raw.replaceAll(RegExp(r'\(\d{4}\)'), ' ');
    raw = raw.replaceAll(RegExp(r'\s+\d{1,3}\s*$'), ' ');
    raw = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (raw.isEmpty) raw = folders.first.name;
    // Title-case-ish: keep original casing but trim to ~32 chars.
    if (raw.length > 40) raw = raw.substring(0, 40).trim();
    return raw;
  }

  Future<String?> _promptGroupNameDialog(String initial) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Group name'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. Girls und Panzer das Finale')),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), child: const Text('Group')),
        ],
      ),
    );
  }

  Future<String?> _promptGroupName(String initial) => _promptGroupNameDialog(initial);

  Future<void> _ungroup(SeriesGroup g) async {
    final mg = _manualForGroup(g);
    if (mg == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Ungroup "${mg.name}"?'),
        content: const Text('The folders will appear as separate cards again.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Ungroup')),
        ],
      ),
    );
    if (ok != true) return;
    final next = _manualGroups.where((m) => m.id != mg.id).toList();
    await ManualGroupsStore.instance.save(next);
    await _loadLibraryFolders();
  }

  bool _ungroupableSelection() {
    if (_selectedIds.isEmpty) return false;
    for (final mg in _manualGroups) {
      if (mg.folderIds.length == _selectedIds.length &&
          mg.folderIds.every(_selectedIds.contains)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _ungroupSelectionAsGroup() async {
    SeriesGroup? target;
    for (final mg in _manualGroups) {
      if (mg.folderIds.length == _selectedIds.length &&
          mg.folderIds.every(_selectedIds.contains)) {
        for (final g in _seriesGroups) {
          if (g.folders.length == mg.folderIds.length &&
              mg.folderIds.every((id) => g.folders.any((f) => f.id == id))) {
            target = g;
            break;
          }
        }
        break;
      }
    }
    target ??= (() {
      for (final g in _seriesGroups) {
        if (g.folders.length == _selectedIds.length &&
            g.folders.every((f) => _selectedIds.contains(f.id))) {
          return g;
        }
      }
      return null;
    })();
    final ids = Set<String>.from(_selectedIds);
    _exitSelection();
    if (target != null) {
      await _ungroup(target);
    } else {
      // Fallback: at least clear the stale selection that matched a
      // just-deleted manual group.
      await _loadLibraryFolders();
      if (ids.isNotEmpty) setState(() => _selectedIds.clear());
    }
  }

  void _onGroupTap(SeriesGroup g) {
    if (_inSelectionMode) {
      _toggleGroupSelection(g);
      return;
    }
    _openGroup(g);
  }

  void _onGroupLongPress(SeriesGroup g) {
    // Long-press enters selection mode (tap toggles the whole group) — the
    // top-right 3-dot menu then offers Group / Remove from library.
    if (_inSelectionMode) {
      _toggleGroupSelection(g);
    } else {
      setState(() => _selectedIds.addAll(g.folders.map((f) => f.id)));
    }
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
    var folders = await LibraryFoldersStore.load();
    // Purge legacy Jellyfin/FTP/DLNA bookmarks (now browse-only).
    final stale = folders.where((f) =>
        f.source == LibraryFolderSource.jellyfin ||
        f.source == LibraryFolderSource.ftp ||
        f.source == LibraryFolderSource.upnp).toList();
    if (stale.isNotEmpty) {
      for (final f in stale) {
        await LibraryFoldersStore.remove(f.id);
      }
      folders = folders.where((f) => !stale.contains(f)).toList();
    }
    final manual = await ManualGroupsStore.instance.load();
    if (!mounted) return;
    final groups = _buildDisplayGroups(folders, manual);
    setState(() {
      _folders = folders;
      _manualGroups = manual;
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
    // Widget tests pump this fire-and-forget path; the connectivity probe's
    // 3s timeout Timer outlives the test binding and trips !timersPending.
    if (_inTests) return;
    final service = TmdService.instance;
    await service.ensureLoaded();
    Future<List<InternetAddress>> probe(String host) async {
      try {
        return await InternetAddress.lookup(host)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        return const [];
      }
    }

    var useTheTvdb = false;
    try {
      useTheTvdb = await TheTvdbClient.isFallbackEnabled() &&
          await TheTvdbClient.defaultCredentialStore.isConfiguredAsync;
    } catch (_) {}
    final hosts = <String>['api.themoviedb.org'];
    if (useTheTvdb) hosts.add('api4.thetvdb.com');
    final connectivity = await Future.wait(hosts.map(probe));
    if (connectivity.every(
      (result) => result.isEmpty || result.first.rawAddress.isEmpty,
    )) {
      debugPrint('Metadata _resolveFolderMeta: offline — skipping resolution');
      return;
    }
    // Regex to detect season-like folder names (S01, Season N, roman numerals).
    // Matches the logic in tmdb_client.dart for staleness check.
    final seasonTagRegex = RegExp(
      r'\bs\d{1,2}\b|\bseason\s*\d+|\b(?:I{1,3}|IV|V|VI{0,3}|IX|X)\b',
      caseSensitive: false,
    );
    for (final folder in folders) {
      final key = folder.metadataKey;
      final existing = service.metaFor(key);
      final hasSeasonTag = seasonTagRegex.hasMatch(folder.name);
      // Only require folderSeason for folders that look like season subfolders.
      // Top-level show folders (e.g. "House") have no folderSeason and that's OK.
      var needsResolve = existing == null ||
          (hasSeasonTag && existing.folderSeason == null &&
              existing.movie.kind != TmdKind.movie);
      // Movie-part staleness: folder "FINALE 02" cached as "Part I" — force
      // re-resolve so the correct numbered query (02 → Part II) can win.
      // Delegate the actual comparison to the service's helpers via a local
      // check to avoid importing parsing logic here.
      if (!needsResolve && existing.movie.kind == TmdKind.movie) {
        final stripped = folder.name.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
        final folderPart = int.tryParse(
            RegExp(r'\b(\d{1,3})\s*$').firstMatch(stripped.trim())?.group(1) ?? '');
        if (folderPart != null) {
          final titleLower = existing.movie.title.toLowerCase();
          final partMatch = RegExp(r'\bpart\s+(\d+|[ivxlcdm]+)\b', caseSensitive: false)
              .firstMatch(titleLower);
          int? cachedPart;
          if (partMatch != null) {
            final raw = partMatch.group(1)!.toUpperCase();
            cachedPart = int.tryParse(raw) ?? _romanToInt(raw);
          }
          if (cachedPart != null && folderPart != cachedPart) {
            needsResolve = true;
          } else if (cachedPart == null) {
            final hasAnyPartMarker = RegExp(
                    r'\b(?:part|vol(?:ume)?|movie|chapter|film)\s+\d+',
                    caseSensitive: false)
                .hasMatch(titleLower);
            if (!hasAnyPartMarker) needsResolve = true;
          }
        }
      }
      debugPrint('TMDB _resolveFolderMeta: folder="${folder.name}" key="$key" existing=${existing != null ? 'meta(${existing.movie.title}, fs=${existing.folderSeason})' : 'null'} needsResolve=$needsResolve');
      if (needsResolve) {
        // List the folder's children so resolveFolder can detect episode/season
        // markers in file OR subfolder names (e.g. S02E05, s02, s03) — without
        // this, a plain folder name always resolves as a movie because
        // parsed.isEpisode is false.
        List<String>? fileNames;
        if (!folder.isFile) {
          try {
            if (folder.source == LibraryFolderSource.files) {
              final entries =
                  await FileBrowserService.instance.listDirectory(folder.path);
              fileNames = entries.map((e) => e.name).toList();
            } else if (folder.source == LibraryFolderSource.smb) {
              final serverId = folder.networkServerId ?? '';
              final share = folder.networkShare ?? '';
              final path = folder.networkPath ?? '';
              final rawEntries =
                  await SmbClient.instance.listDirectory(serverId, share, path);
              fileNames = rawEntries.map((e) => e.name).toList();
            } else if (folder.source == LibraryFolderSource.webdav) {
              final serverId = folder.networkServerId ?? '';
              final path = folder.networkPath ?? '';
              final rawEntries =
                  await WebDavClient.instance.listDirectory(serverId, path);
              fileNames = rawEntries.map((e) => e.name).toList();
            } else if (folder.source == LibraryFolderSource.ftp) {
              final serverId = folder.networkServerId ?? '';
              final path = folder.networkPath ?? '';
              final rawEntries =
                  await FtpClient.instance.listDirectory(serverId, path);
              fileNames = rawEntries.map((e) => e.name).toList();
            } else if (folder.source == LibraryFolderSource.upnp) {
              final serverId = folder.networkServerId ?? '';
              final path = folder.networkPath ?? '';
              final rawEntries =
                  await UpnpClient.instance.browse(serverId, path);
              fileNames = rawEntries.map((e) => e.name).toList();
            } else if (folder.source == LibraryFolderSource.jellyfin) {
              final serverUrl = folder.jellyfinServerUrl ?? '';
              final itemId = folder.jellyfinItemId ?? '';
              final server = await _client.serverForUrl(serverUrl);
              if (server != null && server.isAuthenticated) {
                final rawEntries = await _client.getItems(server, itemId);
                fileNames = rawEntries.map((e) => e.name).toList();
              }
            }
          } catch (_) {}
        }
        try {
          await service.resolveFolder(
            key,
            folder.name,
            yearHint: folder.yearHint,
            fileNames: fileNames,
          );
        } catch (e) {
          debugPrint('TMDB _resolveFolderMeta: resolveFolder FAILED for "$key" ($e)');
          continue;
        }
        debugPrint('TMDB _resolveFolderMeta: resolveFolder OK for "$key", post-resolve meta=${service.metaFor(key) != null ? 'meta(${service.metaFor(key)!.movie.title}, fs=${service.metaFor(key)!.folderSeason})' : 'null'}');
        // Cache episode metadata for ALL locally-present seasons so that
        // episode titles, stills, overviews and ratings are available offline.
        // Without this, only folderSeason episodes are cached — other seasons
        // fail when the user opens the folder without a network connection.
        final postMeta = service.metaFor(key);
        if (postMeta != null &&
            postMeta.movie.kind == TmdKind.tv &&
            fileNames != null) {
          final seasonsNeeded = <int>{};
          for (final name in fileNames) {
            final parsed = ParsedFileName.parse(name);
            if (parsed.isEpisode && parsed.season > 0) {
              seasonsNeeded.add(parsed.season);
            }
          }
          if (postMeta.folderSeason != null) {
            seasonsNeeded.add(postMeta.folderSeason!);
          }
          // Anime bracket numbering ([01]/[02]) — parsed seasons are all 0
          // and folderSeason may be null.  Always fetch season 1 so episode
          // stills resolve to the first (only) season on TMDB.
          if (seasonsNeeded.isEmpty) seasonsNeeded.add(1);
          for (final season in seasonsNeeded) {
            try {
              await service.seasonFor(key, season);
            } catch (_) {}
          }
        }
      }
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

  int? _romanToInt(String roman) {
    const values = {'I': 1, 'V': 5, 'X': 10, 'L': 50, 'C': 100, 'D': 500, 'M': 1000};
    var total = 0;
    var prev = 0;
    for (var i = roman.length - 1; i >= 0; i--) {
      final v = values[roman[i]];
      if (v == null) return null;
      if (v < prev) {
        total -= v;
      } else {
        total += v;
      }
      prev = v;
    }
    return total > 0 ? total : null;
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
      // Deep scan: recursively traverse subdirectories (up to 5 levels)
      // and create one LibraryFolder per video file and subfolder.
      final parentId = picked.bookmarkId ?? 'folder_${DateTime.now().millisecondsSinceEpoch}';
      final rootFolder = LibraryFolder(
        id: parentId,
        name: picked.name,
        path: picked.path,
        addedAt: DateTime.now(),
      );
      final scanDepth = await FolderScanner.savedScanDepth();
      final scanner = FolderScanner(maxDepth: scanDepth);
      final expanded = await scanner.scan(rootFolder);
      if (expanded.isNotEmpty) {
        // Remove old entries from a previous scan of the same root (by
        // parentId or path prefix) and any manually-added entries whose
        // names match an expanded entry.
        final expandedNames = expanded.map((e) => e.name).toSet();
        final rootPathPrefix = '${rootFolder.path.replaceAll(RegExp(r'/+$'), '')}/';
        final existing = await LibraryFoldersStore.load();
        for (final old in existing) {
          if (old.parentId == parentId ||
              expandedNames.contains(old.name) ||
              old.path.startsWith(rootPathPrefix)) {
            await LibraryFoldersStore.remove(old.id);
          }
        }
        await LibraryFoldersStore.bulkAdd(expanded);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${picked.name}" expanded into ${expanded.length} items')),
        );
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

  /// Opens a grouped folder (`Strike the Blood`, `Strike the Blood II`, etc
  /// collapsed into one card). A single-**file** card (an individual video
  /// bookmarked to Home) opens in video mode directly. A folder whose TMDB
  /// match is a **movie** opens the movie details screen (with a Play bar) —
  /// the season/episode view would render a lone film as "Episode 1" with no
  /// way to play it. Everything else opens [SeriesSeasonsScreen] for the
  /// Nova-style season poster grid UI.
  void _openGroup(SeriesGroup group) {
    // Manual groups (user-selected cards) always open MovieGroupScreen —
    // the grid-of-cards pattern, header only when a member has TMDB info.
    if (_isManualGroup(group)) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MovieGroupScreen(
            group: group,
            posterMeta: _manualForGroup(group)?.posterMeta,
            manualGroupId: _manualForGroup(group)?.id,
          ),
        ),
      );
      return;
    }
    // Single-file entries open VIDEO mode via the per-source resolver
    // (WebDAV/Jellyfin/UPnP file entries carry synthetic paths — the real
    // playable URL is rebuilt at tap time).
    if (group.primary.isFile) {
      _openFileEntry(group.primary, group.metadataKey);
      return;
    }
    final meta = TmdService.instance.metaFor(group.metadataKey);
    final isMovie = meta?.movie.kind == TmdKind.movie;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => group.folders.length > 1
            ? SeriesSeasonsScreen(group: group)
            : isMovie
                ? TmdDetailsScreen(folder: group.primary)
                : SeriesSeasonsScreen(group: group),
      ),
    );
  }

  /// Opens a library file entry (VIDEO mode) via [NetworkVideoResolver] —
  /// per-source playable URL (SMB/WebDAV/FTP/UPnP/Jellyfin/local).
  Future<void> _openFileEntry(LibraryFolder folder, String metadataKey) async {
    final video = await NetworkVideoResolver.resolve(folder);
    if (!mounted) return;
    if (video == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Can't open this file — its source is unavailable."),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: video,
          parentMetadataKey: metadataKey,
        ),
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
      // Drop the folder from any manual group (group pruned automatically
      // when it falls below 2 members).
      try {
        await ManualGroupsStore.instance.removeFolderId(f.id);
      } catch (_) {}
      if (f.source == LibraryFolderSource.files) {
        try {
          await FileBrowserService.instance.removeLibraryBookmark(f.id);
        } catch (_) {}
      } else if (f.isJellyfin) {
        try {
          await _client.removeFolderMeta(f.id);
        } catch (_) {}
      }
    }
    // Only clear TMDB metadata when removing the whole group (or the last
    // folder). Removing a single folder from a multi-folder group must NOT
    // clear the shared metadata key — the remaining folders still need it.
    if (foldersToRemove.length >= group.folders.length) {
      try {
        await TmdService.instance.clear(group.metadataKey);
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _folders = _folders
          .where((f) => !foldersToRemove.any((r) => r.id == f.id))
          .toList();
    });
  }

  /// Batch remove: removes every folder in [list] from the library (the
  /// selection-mode 3-dot menu's Remove from library). Same cleanup as
  /// [_removeFolder] — manual-group drop, library bookmark release, and TMDB
  /// clear for each removed group.
  Future<void> _removeFolders(List<LibraryFolder> list) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context).homeRemoveFromLibrary),
        content: Text(
          '${list.length} ${list.length == 1 ? 'item' : 'items'} will no longer '
          'appear here. The files stay on your device.',
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
    for (final f in list) {
      await LibraryFoldersStore.remove(f.id);
      try {
        await ManualGroupsStore.instance.removeFolderId(f.id);
      } catch (_) {}
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
          .where((f) => !list.any((r) => r.id == f.id))
          .toList();
    });
  }

  Future<void> _clearAll() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.library_add_check_outlined),
              title: Text(AppLocalizations.of(context).homeClearLibrary),
              subtitle: Text(
                AppLocalizations.of(context).homeClearLibraryDesc,
              ),
              onTap: () => Navigator.of(context).pop('library'),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: Text(AppLocalizations.of(context).homeClearContinueWatching),
              subtitle: Text(
                AppLocalizations.of(context).homeClearContinueWatchingDesc,
              ),
              onTap: () => Navigator.of(context).pop('continue'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == 'library') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(AppLocalizations.of(context).homeClearLibraryTitle),
          content: Text(AppLocalizations.of(context).homeClearLibraryContent),
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

      for (final f in _folders) {
        if (f.source == LibraryFolderSource.files) {
          try {
            await FileBrowserService.instance.removeLibraryBookmark(f.id);
          } catch (_) {}
        } else if (f.isJellyfin) {
          try {
            await _client.removeFolderMeta(f.id);
          } catch (_) {}
        }
      }
      await LibraryFoldersStore.clearAll();
      if (!mounted) return;
      setState(() {
        _folders = const [];
        _seriesGroups = const [];
        _jellyfinMeta = const {};
      });
    } else if (choice == 'continue') {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            AppLocalizations.of(context).homeClearContinueWatchingTitle,
          ),
          content: Text(
            AppLocalizations.of(context).homeClearContinueWatchingContent,
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
      await ContinueWatchingStore.clearAll();
      if (!mounted) return;
      setState(() => _entries = const []);
    }
  }

  /// Best-effort TMDB lookups so cards can show poster art and real titles
  /// without waiting for a tap. Same tools as the poster-card path: a
  /// file-level resolve (parent-folder name + base-query fallback in
  /// `bestMatch`), then inherit the library folder's `resolveFolder` meta
  /// when the file search still misses (e.g. raw title scores 0).
  Future<void> _resolveMetadata(List<ContinueWatchingEntry> entries) async {
    final service = TmdService.instance;
    await service.ensureLoaded();
    // Folder list may not be loaded yet (fire-and-forget from _loadLibrary).
    final folders = _folders.isNotEmpty ? _folders : await LibraryFoldersStore.load();
    for (final e in entries) {
      final video = e.video;
      final key = TmdStore.identityKeyFor(video);
      if (service.metaFor(key) != null) continue;
      try {
        await service.resolve(
          video,
          parentFolderName:
              _parentFolderNameOf(video.path ?? video.uri ?? ''),
        );
        if (service.metaFor(key) != null) continue;
        // File search missed — inherit the folder poster-card match.
        final folder =
            _matchingLibraryFolder(folders, video.path ?? video.uri);
        if (folder == null) continue;
        var folderMeta = service.metaFor(folder.metadataKey);
        if (folderMeta == null) {
          await service.resolveFolder(
            folder.metadataKey,
            folder.name,
            yearHint: folder.yearHint,
            fileNames: [video.title],
          );
          folderMeta = service.metaFor(folder.metadataKey);
        }
        if (folderMeta != null) {
          await service.carryMeta(folder.metadataKey, key);
        }
      } catch (_) {
        // Network failures are non-fatal; the card just stays a placeholder.
      }
    }
  }

  /// Longest library-folder path that is a prefix of [path] (a video under a
  /// bookmarked folder). Null when the file is outside the library.
  LibraryFolder? _matchingLibraryFolder(
      List<LibraryFolder> folders, String? path) {
    if (path == null || path.isEmpty) return null;
    LibraryFolder? best;
    for (final f in folders) {
      if (f.isFile) continue;
      final fp = f.path;
      if (fp.isEmpty) continue;
      final prefix = fp.endsWith('/') ? fp : '$fp/';
      if (path == fp || path.startsWith(prefix)) {
        if (best == null || fp.length > best.path.length) best = f;
      }
    }
    return best;
  }

  /// Parent directory name of a filesystem path (empty for top-level files).
  static String _parentFolderNameOf(String path) {
    if (path.isEmpty) return '';
    var clean = path.split('?').first.split('#').first;
    if (clean.endsWith('/')) clean = clean.substring(0, clean.length - 1);
    final lastSlash = clean.lastIndexOf('/');
    if (lastSlash <= 0) return '';
    final parent = clean.substring(0, lastSlash);
    final parentSlash = parent.lastIndexOf('/');
    final segment =
        parentSlash >= 0 ? parent.substring(parentSlash + 1) : parent;
    try {
      return Uri.decodeComponent(segment);
    } catch (_) {
      return segment;
    }
  }

  /// Meta for a continue-watching card: the file's own key first, then the
  /// parent library folder's key (poster-card result) so the grid can paint
  /// before/without a per-file resolve.
  TmdMeta? _metaForContinueVideo(VideoItem video) {
    final direct = TmdService.instance.metaFor(TmdStore.identityKeyFor(video));
    if (direct != null) return direct;
    final folder =
        _matchingLibraryFolder(_folders, video.path ?? video.uri);
    if (folder == null) return null;
    return TmdService.instance.metaFor(folder.metadataKey);
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
    return PopScope(
      canPop: !_inSelectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _inSelectionMode) _exitSelection();
      },
      child: Scaffold(
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
              leading: _inSelectionMode
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: _exitSelection,
                    )
                  : Builder(
                      builder: (ctx) => IconButton(
                        icon: const Icon(Icons.menu),
                        onPressed: () => Scaffold.of(ctx).openDrawer(),
                      ),
                    ),
              title: Text(_inSelectionMode ? '${_selectedIds.length} selected' : AppLocalizations.of(context).homeTitle),
              pinned: true,
              actions: [
                if (_inSelectionMode) ...[
                  if (_selectedIds.length >= 2)
                    IconButton(
                      icon: const Icon(Icons.library_add_check),
                      tooltip: 'Group',
                      onPressed: _groupSelected,
                    ),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'group' && _selectedIds.length >= 2) _groupSelected();
                      if (v == 'clear') _exitSelection();
                      if (v == 'ungroup') _ungroupSelectionAsGroup();
                      if (v == 'remove' && _selectedIds.isNotEmpty) {
                        final foldersToRemove = _folders
                            .where((f) => _selectedIds.contains(f.id))
                            .toList();
                        _exitSelection();
                        if (foldersToRemove.length == 1) {
                          _removeFolder(foldersToRemove.first);
                        } else if (foldersToRemove.isNotEmpty) {
                          _removeFolders(foldersToRemove);
                        }
                      }
                    },
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                        value: 'group',
                        enabled: _selectedIds.length >= 2,
                        child: const Text('Group'),
                      ),
                      if (_ungroupableSelection())
                        const PopupMenuItem(value: 'ungroup', child: Text('Ungroup')),
                      if (_selectedIds.isNotEmpty)
                        const PopupMenuItem(value: 'remove', child: Text('Remove from library')),
                      const PopupMenuItem(value: 'clear', child: Text('Clear selection')),
                    ],
                  ),
                ] else if (_seriesGroups.isNotEmpty || _entries.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.delete_sweep_outlined),
                    tooltip: AppLocalizations.of(context).homeClearAll,
                    onPressed: _clearAll,
                  ),
              ],
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
                    tmdbMeta: _metaForGroupDisplay(group),
                    jellyfinInfo: _jellyfinMeta[group.primary.id],
                    groupCount: group.folders.length,
                    selected: _isGroupSelected(group),
                    displayNameOverride: _manualForGroup(group)?.name,
                    onTap: () => _onGroupTap(group),
                    onLongPress: () => _onGroupLongPress(group),
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
      floatingActionButton: _inSelectionMode
          ? null
          : FloatingActionButton(
              onPressed: _showAddMenu,
              tooltip: 'Add a source',
              child: const Icon(Icons.add),
            ),
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
    unawaited(() async {
      final def = await DefaultEngineStore.load();
      if (!mounted) return;
      await Navigator.of(context).push(
        PlayerScreen.route(
          video: VideoItem(
            id: job.id,
            title: job.title,
            path: job.destPath,
            duration: Duration.zero,
            sizeBytes: job.totalBytes > 0 ? job.totalBytes : null,
          ),
          initialEngine: def == DefaultEngine.mpv
              ? PlayEngine.mpv
              : PlayEngine.media3,
        ),
      );
    }());
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
    unawaited(() async {
      final def = await DefaultEngineStore.load();
      if (!mounted) return;
      await Navigator.of(context).push(
        PlayerScreen.route(
          video: VideoItem(
            id: job.id,
            title: job.title,
            path: job.destPath,
            duration: Duration.zero,
            sizeBytes: job.totalBytes > 0 ? job.totalBytes : null,
          ),
          initialEngine: def == DefaultEngine.mpv
              ? PlayEngine.mpv
              : PlayEngine.media3,
        ),
      );
    }());
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
          tmdbMeta: _metaForContinueVideo(video),
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
        tmdbMeta: _metaForContinueVideo(video),
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
    final def = await DefaultEngineStore.load();
    if (!mounted) return;
    await Navigator.of(context).push(
      PlayerScreen.route(
        initialEngine: def == DefaultEngine.mpv
            ? PlayEngine.mpv
            : PlayEngine.media3,
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
