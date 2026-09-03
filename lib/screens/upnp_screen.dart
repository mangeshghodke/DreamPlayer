import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/jellyfin_client.dart';
import '../services/tmdb_client.dart';
import '../services/upnp_client.dart';
import '../services/watched_store.dart';
import '../utils/file_info_extractor.dart';
import '../utils/tv_helper.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/tv_tile.dart';
import 'tmd_details_screen.dart';

class UpnpScreen extends StatefulWidget {
  const UpnpScreen({super.key});

  @override
  State<UpnpScreen> createState() => _UpnpScreenState();
}

class _UpnpScreenState extends State<UpnpScreen> {
  static final _epPattern = RegExp(
      r'\b(?:S\d{1,2}E\d{1,2}|\d{1,2}x\d{1,3}|E(?:P)?\d{1,3})\b|\[(\d{1,3})\]',
      caseSensitive: false);

  List<UpnpServer> _servers = const [];
  bool _discovering = false;
  String? _discoverError;
  List<String> _diag = const [];

  // Browser state (when a server is selected)
  UpnpServer? _activeServer;
  List<_UpnpCrumb> _crumbs = const [];
  List<UpnpEntry> _entries = const [];
  bool _browsing = false;
  String? _browseError;
  bool _isSeriesFolder = false;

  /// Watched marks for the current folder, keyed by the same stable resume
  /// key each video uses for playback.
  Set<String> _watchedKeys = {};

  @override
  void initState() {
    super.initState();
    TmdService.instance.addListener(_onTmdbChanged);
    _discover();
  }

  @override
  void dispose() {
    TmdService.instance.removeListener(_onTmdbChanged);
    super.dispose();
  }

  void _onTmdbChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _discover() async {
    setState(() {
      _discovering = true;
      _discoverError = null;
      _diag = const [];
    });
    try {
      final servers = await UpnpClient.instance.discover();
      final diag = await UpnpClient.instance.diagnostics();
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _diag = diag ?? const [];
        _discovering = false;
      });
    } on PlatformException catch (e) {
      final diag = await UpnpClient.instance.diagnostics();
      if (!mounted) return;
      setState(() {
        _discovering = false;
        _discoverError = e.message ?? 'Discovery failed';
        _diag = diag ?? const [];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _discovering = false;
        _discoverError = e.toString();
      });
    }
  }

  Future<void> _openServer(UpnpServer server) async {
    setState(() {
      _activeServer = server;
      _crumbs = [_UpnpCrumb(id: '0', name: server.name)];
      _entries = const [];
      _browseError = null;
    });
    await _browse(server, '0');
  }

  Future<void> _browse(UpnpServer server, String objectId) async {
    setState(() {
      _browsing = true;
      _browseError = null;
      _diag = const [];
      _isSeriesFolder = false;
    });
    try {
      final entries = await UpnpClient.instance.browse(server.id, objectId);
      final diag = await UpnpClient.instance.diagnostics();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _diag = diag ?? const [];
        _browsing = false;
      });
      _prefetchTmdbMeta(entries);
      _detectAndLoadSeriesFolder(entries);
      _refreshWatched();
    } on PlatformException catch (e) {
      final diag = await UpnpClient.instance.diagnostics();
      if (!mounted) return;
      setState(() {
        _browsing = false;
        _browseError = e.message ?? 'Browse failed';
        _diag = diag ?? const [];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _browsing = false;
        _browseError = e.toString();
      });
    }
  }

  Future<void> _onRefresh() async {
    final server = _activeServer;
    if (server == null || _crumbs.isEmpty) return;
    await UpnpClient.instance.invalidateListingCache(serverId: server.id);
    await _browse(server, _crumbs.last.id);
  }

  /// Best-effort TMDB prefetch for the current folder's video files.
  void _prefetchTmdbMeta(List<UpnpEntry> entries) {
    final service = TmdService.instance;
    for (final entry in entries) {
      if (entry.isDirectory || entry.url == null) continue;
      service.resolve(VideoItem(
        id: _identityKey(entry),
        title: entry.name,
        uri: entry.url!,
        resumeKey: _identityKey(entry),
        duration: Duration.zero,
        sizeBytes: entry.size,
      )).catchError((_) => null as TmdMeta?);
    }
  }

  String _identityKey(UpnpEntry entry) {
    final serverId = _activeServer?.id ?? 'upnp';
    return 'upnp:$serverId/${entry.id}';
  }

  Future<void> _refreshWatched() async {
    try {
      final watched = await WatchedStore.load();
      if (mounted) setState(() => _watchedKeys = watched);
    } catch (_) {}
  }

  Future<void> _toggleWatched(UpnpEntry entry) async {
    final key = _identityKey(entry);
    final now = !_watchedKeys.contains(key);
    setState(() {
      _watchedKeys = {..._watchedKeys};
      now ? _watchedKeys.add(key) : _watchedKeys.remove(key);
    });
    try {
      await WatchedStore.set(key, now);
    } catch (_) {}
  }

  /// Detect TV series folder + fetch TMDB header metadata (Nova-style).
  Future<void> _detectAndLoadSeriesFolder(List<UpnpEntry> entries) async {
    final server = _activeServer;
    if (server == null) return;
    final videos = entries.where((e) => !e.isDirectory).toList();
    if (videos.isEmpty) return;
    final episodes = videos
        .where((e) => ParsedFileName.parse(e.name).isEpisode || _epPattern.hasMatch(e.name))
        .toList();
    if (episodes.isEmpty || episodes.length < 2) return;
    final crumbName = _crumbs.last.name;
    final metadataKey = 'upnp_folder:${server.id}/${_crumbs.last.id}';
    final service = TmdService.instance;
    await service.ensureLoaded();
    final meta = service.metaFor(metadataKey) ??
        await service.resolveFolder(metadataKey, crumbName);
    if (meta == null || !mounted) return;
    setState(() {
      _isSeriesFolder = true;
    });
    await service.detailsFor(metadataKey);
    if (!mounted) return;
    final seasonsNeeded = <int>{};
    for (final e in episodes) {
      final s = ParsedFileName.parse(e.name).season;
      if (s > 0) seasonsNeeded.add(s);
    }
    if (meta.folderSeason != null) seasonsNeeded.add(meta.folderSeason!);
    for (final season in seasonsNeeded) {
      await service.seasonFor(metadataKey, season);
      if (!mounted) return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _onEntryTap(UpnpEntry entry) async {
    final server = _activeServer;
    if (server == null) return;
    if (entry.isDirectory) {
      setState(() {
        _crumbs = [..._crumbs, _UpnpCrumb(id: entry.id, name: entry.name)];
      });
      _browse(server, entry.id);
      return;
    }
    if (entry.url == null || entry.url!.isEmpty) return;
    final key = _identityKey(entry);
    // Jellyfin DLNA servers transcode items with external subtitles to a
    // lossy unseekable H.264 TS stream (kills HDR). If this URL is one of
    // those and the host is a saved Jellyfin server, play direct instead.
    VideoItem? video = await JellyfinClient().upgradeDlnaUrl(
      url: entry.url!,
      title: entry.name,
      sizeBytes: entry.size,
    );
    video ??= () {
      final fi = extractFileInfo(entry.name);
      return VideoItem(
        id: key,
        title: entry.name,
        uri: entry.url!,
        resumeKey: key,
        duration: Duration.zero,
        sizeBytes: entry.size,
        // Server declared DLNA.ORG_CI=1 — this URL is a live transcode.
        isTranscoded: entry.transcoded,
        // Server-advertised subtitle resources (Jellyfin DeliveryUrls) become
        // selectable tracks even on the raw DLNA path.
        externalSubtitles: entry.externalSubs
            .asMap()
            .entries
            .map((e) => VideoExternalSub(
                  uri: e.value.url,
                  label:
                      'Subtitle ${e.key + 1} · ${e.value.extension.toUpperCase()}',
                  mimeType: e.value.mimeType,
                ))
            .toList(),
        videoCodec: fi.videoCodec,
        audioCodec: fi.audioCodec,
        audioChannels: fi.audioChannels,
      audioLanguage: fi.audioLanguage,
        resolution: fi.resolution,
      fps: fi.fps,
        hdrHint: fi.hdrHint,
      );
    }();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: video!,
          parentMetadataKey: _isSeriesFolder
              ? 'upnp_folder:${server.id}/${_crumbs.last.id}'
              : null,
        ),
      ),
    );
  }

  Future<bool> _onWillPop() async {
    if (_activeServer != null) {
      if (_crumbs.length > 1) {
        final parent = _crumbs[_crumbs.length - 2];
        setState(() => _crumbs = _crumbs.sublist(0, _crumbs.length - 1));
        await _browse(_activeServer!, parent.id);
        return false;
      }
      setState(() {
        _activeServer = null;
        _crumbs = const [];
        _entries = const [];
        _browseError = null;
      });
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final tv = isTvMode(context);
    final isBrowsingServer = _activeServer != null;

    return PopScope(
      canPop: !isBrowsingServer || _crumbs.length <= 1,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _onWillPop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(isBrowsingServer ? (_activeServer!.name) : 'DLNA'),
          actions: [
            if (!isBrowsingServer)
              IconButton(
                icon: _discovering
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
                onPressed: _discovering ? null : _discover,
                tooltip: 'Discover',
              ),
          ],
        ),
        body: TvOverscan(
          child: isBrowsingServer ? _buildBrowser(tv) : _buildServerList(tv),
        ),
      ),
    );
  }

  Widget _buildServerList(bool tv) {
    if (_discovering && _servers.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_discoverError != null && _servers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_discoverError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _discover, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_servers.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cast_connected_outlined, size: 48),
            const SizedBox(height: 12),
            const Text('No DLNA servers found', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              '1. Allow Local Network when prompted (Settings → Privacy & Security → Local Network → DreamPlayer).\n'
              '2. iPad and the server must be on the same Wi-Fi.\n'
              '3. Tap Discover again after granting.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: _discover, icon: const Icon(Icons.refresh), label: const Text('Discover again')),
            if (_diag.isNotEmpty) ...[
              const SizedBox(height: 20),
              Align(alignment: Alignment.centerLeft, child: Text('Diagnostics', style: Theme.of(context).textTheme.titleSmall)),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_diag.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              ),
            ],
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: _servers.length,
      separatorBuilder: (context, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final s = _servers[i];
        return TvTile(
          leading: const Icon(Icons.dns_outlined),
          title: Text(s.name),
          subtitle: Text(s.location, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openServer(s),
        );
      },
    );
  }

  Widget _buildBrowser(bool tv) {
    final crumbs = _crumbs;
    return Column(
      children: [
        // Breadcrumb + back
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () async {
                    if (!await _onWillPop() && mounted) setState(() {});
                  },
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (int i = 0; i < crumbs.length; i++) ...[
                          if (i > 0) const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Text('›')),
                          InkWell(
                            onTap: i == crumbs.length - 1
                                ? null
                                : () async {
                                    final target = crumbs[i];
                                    setState(() => _crumbs = crumbs.sublist(0, i + 1));
                                    await _browse(_activeServer!, target.id);
                                  },
                            child: Text(
                              crumbs[i].name,
                              style: TextStyle(
                                fontWeight: i == crumbs.length - 1 ? FontWeight.w600 : FontWeight.w400,
                                color: i == crumbs.length - 1 ? null : Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                IconButton(icon: const Icon(Icons.refresh), onPressed: () => _browse(_activeServer!, crumbs.last.id)),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _browsing
              ? const Center(child: CircularProgressIndicator())
              : _browseError != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_browseError!, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            FilledButton(onPressed: () => _browse(_activeServer!, crumbs.last.id), child: const Text('Retry')),
                          ],
                        ),
                      ),
                    )
                  : _entries.isEmpty
                      ? SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Nothing here'),
                              if (_diag.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(_diag.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                                ),
                              ],
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _onRefresh,
                          child: ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: _entries.length,
                            separatorBuilder: (context, _) => const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final e = _entries[i];
                              final isDir = e.isDirectory;
                              final posterUrl = isDir
                                  ? null
                                  : posterUrlOf(TmdService.instance.metaFor(_identityKey(e)));
                              final watched = !isDir &&
                                  _watchedKeys.contains(_identityKey(e));
                              return TvTile(
                                leading: posterUrl != null
                                    ? _Poster(posterUrl: posterUrl)
                                    : Icon(isDir ? Icons.folder_outlined : Icons.movie_outlined),
                                title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: isDir ? null : (e.size > 0 ? Text(_formatBytes(e.size)) : null),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!isDir)
                                      IconButton(
                                        tooltip: watched
                                            ? 'Mark as unwatched'
                                            : 'Mark as watched',
                                        icon: Icon(
                                          watched
                                              ? Icons.check_circle
                                              : Icons.check_circle_outline,
                                          color: watched
                                              ? Colors.green.shade400
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                        ),
                                        onPressed: () => _toggleWatched(e),
                                      ),
                                    Icon(isDir
                                        ? Icons.chevron_right
                                        : Icons.play_arrow),
                                  ],
                                ),
                                onTap: () => _onEntryTap(e),
                              );
                            },
                          ),
                        ),
        ),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

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
          Icons.movie_outlined,
          color: Theme.of(context).colorScheme.secondary,
        ),
      ),
    );
  }
}

class _UpnpCrumb {
  const _UpnpCrumb({required this.id, required this.name});
  final String id;
  final String name;
}
