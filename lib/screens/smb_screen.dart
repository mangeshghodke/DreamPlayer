import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/library_folders.dart';
import '../services/simkl_client.dart';
import '../services/smb_client.dart';
import '../services/tmdb_client.dart';
import '../services/watched_store.dart';
import '../widgets/server_form_kit.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/tv_text_field.dart';
import '../widgets/tv_tile.dart';
import 'tmd_details_screen.dart';

/// SMB / LAN-share browser: saved servers -> shares -> folders -> videos.
/// Playback streams through the native SMB client (local proxy URL on iOS);
/// tapping a video opens a single `openShare` URL, torn down on return.
class SmbScreen extends StatefulWidget {
  const SmbScreen({super.key});

  @override
  State<SmbScreen> createState() => _SmbScreenState();
}

class _SmbScreenState extends State<SmbScreen> {
  static final SmbClient _smb = SmbClient.instance;

  List<SmbServer> _servers = const [];
  SmbServer? _browsing;
  String _share = '';
  String _path = '';
  List<SmbEntry> _entries = const [];
  final Map<String, TmdMeta?> _tmdbMeta = {};
  bool _loading = true;
  String? _error;

  /// Saved-server reachability dots (`id` -> online?); probed asynchronously.
  final Map<String, bool> _statuses = {};

  /// LAN discovery results shown above the saved-server list.
  List<SmbDiscovered> _discovered = const [];
  bool _scanning = false;

  /// True while opening the tapped video's stream URL.
  bool _opening = false;

  /// Watched marks keyed by the same `smb:$id/$_share/${path}` used for
  /// `TmdService.resolve` and `VideoItem.resumeKey` — shows a green check
  /// on every file row.
  Set<String> _watchedKeys = {};

  bool get _atBrowseRoot => _browsing == null || (_share.isEmpty && _path.isEmpty);

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  @override
  void dispose() {
    final server = _browsing;
    if (server != null) {
      _smb.closeShare(server.id);
    }
    super.dispose();
  }

  Future<void> _loadServers() async {
    setState(() {
      _loading = true;
      _error = null;
      _statuses.clear();
    });
    try {
      final servers = await _smb.listServers();
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _loading = false;
      });
      _probeStatuses(servers);
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message ?? 'Something went wrong';
          _loading = false;
        });
      }
    }
  }

  /// Fires a quick TCP-445 probe per saved server (in parallel) to paint the
  /// online/offline dots.
  Future<void> _probeStatuses(List<SmbServer> servers) async {
    if (servers.isEmpty) return;
    final results = await Future.wait([
      for (final s in servers) _smb.checkServer(s.host, s.port).then((ok) => (s.id, ok)),
    ]);
    if (!mounted) return;
    setState(() {
      for (final (id, ok) in results) {
        _statuses[id] = ok;
      }
    });
  }

  /// LAN scan for reachable SMB hosts (native subnet 445 probe).
  Future<void> _discover() async {
    setState(() {
      _scanning = true;
      _discovered = const [];
    });
    try {
      final found = await _smb.discoverServers();
      if (!mounted) return;
      setState(() {
        _discovered = found;
        _scanning = false;
      });
    } on PlatformException {
      if (!mounted) return;
      setState(() => _scanning = false);
    }
  }

  Future<void> _openServer(SmbServer server) async {
    setState(() {
      _browsing = server;
      _share = '';
      _path = '';
      _loading = true;
      _error = null;
    });
    try {
      final shares = await _smb.listShares(server.id);
      if (!mounted) return;
      setState(() {
        _entries = shares;
        _loading = false;
      });
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message ?? 'Something went wrong';
          _loading = false;
        });
      }
    }
  }

  String _watchedKeyFor(SmbEntry entry) {
    final server = _browsing;
    if (server == null || entry.isDirectory) return '';
    return 'smb:${server.id}/$_share/${entry.path}';
  }

  Future<void> _refreshWatched() async {
    try {
      final watched = await WatchedStore.load();
      if (mounted) setState(() => _watchedKeys = watched);
    } catch (_) {}
  }

  Future<void> _toggleWatched(SmbEntry entry) async {
    final key = _watchedKeyFor(entry);
    if (key.isEmpty) return;
    final now = !_watchedKeys.contains(key);
    setState(() {
      _watchedKeys = {..._watchedKeys};
      now ? _watchedKeys.add(key) : _watchedKeys.remove(key);
    });
    try {
      await WatchedStore.set(key, now);
    } catch (_) {}
  }

  bool _syncingSimkl = false;

  Future<void> _bookmarkCurrentFolder() async {
    final server = _browsing;
    if (server == null || _share.isEmpty) return;
    final cleanPath = _path.replaceAll(RegExp(r'/+$'), '');
    final folderName = cleanPath.isEmpty ? _share : cleanPath.split('/').last;
    final repoPath = cleanPath.isEmpty ? _share : '$_share/$cleanPath';
    final id = 'smb_${server.id}_${repoPath.hashCode}';
    final folder = LibraryFolder(
      id: id,
      name: folderName,
      path: 'smb:${server.id}/$repoPath',
      addedAt: DateTime.now(),
      source: LibraryFolderSource.smb,
      networkServerId: server.id,
      networkShare: _share,
      networkPath: cleanPath,
      networkLabel: server.name,
    );
    await LibraryFoldersStore.add(folder);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bookmarked $folderName to Home (SMB · ${server.name})')),
      );
    }
  }

  Future<void> _syncFromSimkl() async {
    final client = SimklClient();
    if (!client.isConfigured) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SIMKL not configured')),
        );
      }
      return;
    }
    if (!await client.isAuthenticated()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign in to SIMKL first')),
        );
      }
      return;
    }
    setState(() => _syncingSimkl = true);
    try {
      final watched = await client.fetchWatched();
      int marked = 0;
      for (final entry in _entries) {
        if (entry.isDirectory) continue;
        final key = _watchedKeyFor(entry);
        if (key.isEmpty || _watchedKeys.contains(key)) continue;
        final meta = _tmdbMeta[entry.path];
        if (meta == null) continue;
        final id = meta.movie.id;
        final isTv = meta.movie.kind == TmdKind.tv;
        final shouldMark = isTv ? watched.showSeasons.containsKey(id) : watched.movieIds.contains(id);
        // For episodes, also ensure season is in map (already counts as watched show).
        if (shouldMark) {
          await WatchedStore.set(key, true);
          marked++;
        }
      }
      await _refreshWatched();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(marked > 0 ? 'Marked $marked as watched from SIMKL' : 'Nothing new from SIMKL')),
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

  Future<void> _loadDirectory(String path) async {
    final server = _browsing;
    if (server == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _smb.listDirectory(server.id, _share, path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _entries = entries;
        _loading = false;
      });
      _refreshWatched();
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message ?? 'Something went wrong';
          _loading = false;
        });
      }
    }
  }



  Future<void> _openEntry(SmbEntry entry) async {
    if (entry.isDirectory) {
      if (_share.isEmpty) {
        // Tapping a share in the shares list: this entry IS the share. The
        // share name lives in `_share` (a folder path is relative to it), so
        // set it before listing the share's root.
        setState(() {
          _share = entry.path;
          _path = '';
        });
        await _loadDirectory('');
      } else {
        await _loadDirectory(entry.path);
      }
      return;
    }

    final server = _browsing;
    if (server == null || _opening) return;

    // Only the tapped video's stream URL is needed (play-next was removed), so
    // open just it and navigate immediately — the folder loop that opened every
    // video up-front made TMDB details feel slow (ring spinner while N serial
    // openShare round-trips ran).
    final index = _entries.indexWhere((e) => !e.isDirectory && e.path == entry.path);
    if (index < 0) return;
    final video = _entries[index];

    setState(() => _opening = true);
    String? videoUrl;
    List<VideoExternalSub> externalSubs = const [];
    String? subtitleUrl;
    try {
      videoUrl = await _smb.openShare(server.id, _share, video.path);
      // All matching subtitles (video.srt, video.eng.srt, ...).
      final subPaths = video.subtitlePaths ?? (video.subtitlePath != null ? [video.subtitlePath!] : const <String>[]);
      if (subPaths.isNotEmpty) {
        final subs = <VideoExternalSub>[];
        for (final p in subPaths) {
          try {
            final u = await _smb.openShare(server.id, _share, p);
            final ext = p.split('.').last.toLowerCase();
            final mime = ext == 'ass' || ext == 'ssa'
                ? 'text/x-ssa'
                : ext == 'vtt'
                    ? 'text/vtt'
                    : 'application/x-subrip';
            subs.add(VideoExternalSub(
              uri: u,
              label: p.split('/').last,
              language: '',
              mimeType: mime,
              isDefault: subs.isEmpty,
            ));
          } catch (_) {}
        }
        if (subs.isNotEmpty) {
          externalSubs = subs;
          // Don't set subtitleUrl — externalSubs already carries all tracks.
          // Setting both would duplicate the first track in CC (1 + N).
          subtitleUrl = null;
        }
      }
    } on PlatformException {
      videoUrl = null;
    } finally {
      if (mounted) setState(() => _opening = false);
    }

    if (!mounted) return;
    if (videoUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open ${entry.name}')),
      );
      return;
    }

    final item = VideoItem(
      id: 'smb:${video.path}_${DateTime.now().microsecondsSinceEpoch}',
      title: video.name,
      uri: videoUrl,
      resumeKey: 'smb:${server.id}/$_share/${video.path}',
      subtitleUri: subtitleUrl,
      externalSubtitles: externalSubs,
      duration: Duration.zero,
      sizeBytes: video.size,
    );

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(video: item),
      ),
    );
    // Playback session over: tear down the SMB stream and disconnect.
    _smb.closeShare(server.id);
  }

  Future<void> _goUp() async {
    if (_browsing == null) {
      Navigator.of(context).pop();
      return;
    }
    if (_path.isNotEmpty) {
      final slash = _path.lastIndexOf('/');
      await _loadDirectory(slash < 0 ? '' : _path.substring(0, slash));
    } else if (_share.isNotEmpty) {
      setState(() {
        _share = '';
        _path = '';
        _loading = true;
      });
      try {
        final shares = await _smb.listShares(_browsing!.id);
        if (!mounted) return;
        setState(() {
          _entries = shares;
          _loading = false;
        });
      } on PlatformException catch (e) {
        if (mounted) {
          setState(() {
            _error = e.message ?? 'Something went wrong';
            _loading = false;
          });
        }
      }
    } else {
      setState(() {
        _browsing = null;
        _share = '';
        _path = '';
        _loading = false;
      });
      await _loadServers();
    }
  }

  void _addServer() => _showServerDialog();

  Future<void> _addShare() async {
    final server = _browsing;
    if (server == null) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => serverDialog(
        title: const ServerDialogTitle(
          icon: Icons.folder_special_outlined,
          title: 'Add share',
        ),
        content: ServerTextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
          decoration: serverFieldDecoration(
            context,
            label: 'Share name',
            hint: 'e.g. Videos',
            icon: Icons.folder_open_outlined,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    await _smb.addShare(server.id, name);
    if (!mounted) return;
    await _openServer(server);
  }

  void _editServer(SmbServer server) => _showServerDialog(existing: server);

  void _addDiscoveredServer(SmbDiscovered d) => _showServerDialog(
        initialHost: d.host,
        initialName: d.hostname != d.host ? d.hostname : null,
      );

  Future<void> _deleteServer(SmbServer server) async {
    await _smb.deleteServer(server.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Removed ${server.name}')));
    _loadServers();
  }

  void _showServerDialog({
    SmbServer? existing,
    String? initialHost,
    String? initialName,
  }) {
    showDialog<void>(
      context: context,
      builder: (_) => _ServerFormDialog(
        existing: existing,
        initialHost: initialHost,
        initialName: initialName,
        onSave: () => _loadServers(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final browsing = _browsing;
    return Scaffold(
      appBar: AppBar(
        title: Text(browsing == null
            ? 'Network shares'
            : _breadcrumbTitle(browsing)),
        leading: browsing != null
            ? IconButton(
                tooltip: 'Up',
                icon: const Icon(Icons.arrow_back),
                onPressed: _goUp,
              )
            : null,
        actions: [
          if (browsing != null && _share.isNotEmpty && !_loading)
            IconButton(
              tooltip: 'Bookmark this folder to Home',
              icon: const Icon(Icons.bookmark_add_outlined),
              onPressed: _bookmarkCurrentFolder,
            ),
          if (browsing != null && _share.isNotEmpty && !_loading)
            IconButton(
              tooltip: 'Sync watched from SIMKL',
              icon: _syncingSimkl
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_done_outlined),
              onPressed: _syncingSimkl ? null : _syncFromSimkl,
            ),
          if (browsing != null)
            IconButton(
              tooltip: 'Server list',
              icon: const Icon(Icons.dns_outlined),
              onPressed: () => setState(() {
                _browsing = null;
                _share = '';
                _path = '';
                _loading = false;
              }),
            ),
        ],
      ),
      floatingActionButton: browsing == null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_scanning)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  FloatingActionButton(
                    heroTag: 'smb_scan',
                    onPressed: _discover,
                    tooltip: 'Scan network',
                    child: const Icon(Icons.wifi_find),
                  ),
                const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'smb_refresh',
                  onPressed: _loadServers,
                  tooltip: 'Refresh',
                  child: const Icon(Icons.refresh),
                ),
                const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'smb_add',
                  onPressed: _addServer,
                  tooltip: 'Add server',
                  child: const Icon(Icons.add),
                ),
              ],
            )
          : _share.isEmpty
              ? FloatingActionButton(
                  heroTag: 'smb_add_share',
                  onPressed: _addShare,
                  tooltip: 'Add share',
                  child: const Icon(Icons.add),
                )
              : null,
      body: TvOverscan(child: _body(context)),
    );
  }

  String _breadcrumbTitle(SmbServer server) {
    if (_share.isEmpty) return server.name;
    if (_path.isEmpty) return '${server.name} / $_share';
    final folder = _path.split('/').last;
    return '${server.name} / $_share / $folder';
  }

  Widget _body(BuildContext context) {
    if (_opening) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 64),
              const SizedBox(height: 16),
              Text('Error: $_error',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _atBrowseRoot ? _loadServers : _goUp,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_browsing == null) return _serverList(context);
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _share.isEmpty
                ? 'No shares found. Tap "Add share" and enter the name '
                    'manually if your NAS uses an unusual share name.'
                : 'Nothing here',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final key = _watchedKeyFor(entry);
        return _SmbTile(
          entry: entry,
          onTap: () => _openEntry(entry),
          tmdbMeta: _tmdbMeta[entry.path],
          watched: key.isNotEmpty && _watchedKeys.contains(key),
          onToggleWatched: () => _toggleWatched(entry),
        );
      },
    );
  }

  Widget _serverList(BuildContext context) {
    if (_servers.isEmpty && _discovered.isEmpty && !_scanning) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 48, color: Colors.white38),
            SizedBox(height: 12),
              Text(
                'Nothing yet',
                style: TextStyle(color: Colors.white54),
              ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadServers,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (_scanning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Scanning your network…'),
                ],
              ),
            ),
          if (!_scanning && _discovered.isNotEmpty) ...[
            const _SectionHeader('Detected on this network'),
            for (final d in _discovered)
              TvTile(
                leading: const Icon(Icons.lan_outlined),
                title: Text(
                  d.hostname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  d.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.add_circle_outline),
                onTap: () => _addDiscoveredServer(d),
              ),
          ],
          if (_servers.isNotEmpty) ...[
            const _SectionHeader('Saved servers'),
            for (final server in _servers) _serverTile(server),
          ],
        ],
      ),
    );
  }

  Widget _serverTile(SmbServer server) {
    final status = _statuses[server.id];
    final dot = Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: status == null
            ? Colors.grey.shade600
            : status
                ? Colors.lightGreenAccent
                : Colors.redAccent,
        border: Border.all(color: Colors.black, width: 1.5),
      ),
    );
    return TvTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.dns),
          Positioned(right: -3, bottom: -3, child: dot),
        ],
      ),
      title: Text(
        server.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        server.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (action) {
          if (action == 'edit') {
            _editServer(server);
          } else if (action == 'delete') {
            _deleteServer(server);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      onTap: () => _openServer(server),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _SmbTile extends StatelessWidget {
  const _SmbTile({
    required this.entry,
    required this.onTap,
    this.tmdbMeta,
    this.watched = false,
    this.onToggleWatched,
  });

  final SmbEntry entry;
  final VoidCallback onTap;
  final TmdMeta? tmdbMeta;
  final bool watched;
  final VoidCallback? onToggleWatched;

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
    final colorScheme = Theme.of(context).colorScheme;
    final icon = entry.isDirectory
        ? Icons.folder
        : Icons.play_circle_outline;
    final color = entry.isDirectory ? colorScheme.primary : colorScheme.secondary;
    final subtitle = entry.isDirectory ? null : _sizeLabel(entry.size);
    final posterUrl = tmdbMeta?.movie.posterPath != null
        ? 'https://image.tmdb.org/t/p/w185${tmdbMeta!.movie.posterPath}'
        : null;

    return TvTile(
      leading: posterUrl != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                posterUrl,
                width: 48,
                height: 72,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(icon, color: color),
              ),
            )
          : Icon(icon, color: color),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: entry.isDirectory
          ? const Icon(Icons.chevron_right)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (watched)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.check_circle, color: Colors.green, size: 20),
                  ),
                if (onToggleWatched != null)
                  IconButton(
                    tooltip: watched ? 'Mark as unwatched' : 'Mark as watched',
                    icon: Icon(
                      watched ? Icons.check_circle : Icons.check_circle_outline,
                      color: watched ? Colors.green.shade400 : Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 22,
                    ),
                    onPressed: onToggleWatched,
                  ),
              ],
            ),
      onTap: onTap,
    );
  }
}

class _ServerFormDialog extends StatefulWidget {
  const _ServerFormDialog({
    this.existing,
    this.initialHost,
    this.initialName,
    this.onSave,
  });

  final SmbServer? existing;
  final String? initialHost;
  final String? initialName;
  final VoidCallback? onSave;

  @override
  State<_ServerFormDialog> createState() => _ServerFormDialogState();
}

class _ServerFormDialogState extends State<_ServerFormDialog> {
  static final SmbClient _smb = SmbClient.instance;

  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _domain;
  late bool _guest;
  bool _testing = false;
  String? _resultMessage;
  bool? _resultSuccess;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _name = TextEditingController(text: s?.name ?? widget.initialName ?? '');
    _host = TextEditingController(text: s?.host ?? widget.initialHost ?? '');
    _port = TextEditingController(
        text: (s?.port ?? 445).toString());
    _username = TextEditingController(text: s?.username ?? '');
    _password = TextEditingController(text: '');
    _domain = TextEditingController(text: s?.domain ?? '');
    _guest = s?.anonymous ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _domain.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _resultMessage = null;
    });
    final result = await _smb.testConnection(
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 445,
      username: _username.text.trim(),
      password: _password.text,
      domain: _domain.text.trim(),
      anonymous: _guest,
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _resultSuccess = result.ok;
      _resultMessage =
          result.ok ? 'Connected' : 'Failed: ${result.error ?? 'unknown error'}';
    });
  }

  Future<void> _save() async {
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() {
        _resultSuccess = false;
        _resultMessage = 'Host is required';
      });
      return;
    }
    try {
      await _smb.saveServer(
        id: widget.existing?.id,
        name: _name.text.trim(),
        host: host,
        port: int.tryParse(_port.text.trim()) ?? 445,
        username: _username.text.trim(),
        password: _password.text,
        domain: _domain.text.trim(),
        anonymous: _guest,
      );
      widget.onSave?.call();
      if (mounted) Navigator.of(context).pop();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _resultSuccess = false;
        _resultMessage = e.message ?? 'Save failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return serverDialog(
      title: ServerDialogTitle(
        icon: widget.existing == null ? Icons.add_link : Icons.dns_outlined,
        title: widget.existing == null ? 'Add server' : 'Edit server',
        subtitle: 'SMB / network share',
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TvTextField(
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      decoration: serverFieldDecoration(
                        context,
                        label: 'Name',
                        hint: 'e.g. Living room NAS',
                        icon: Icons.badge_outlined,
                        optional: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: TvTextField(
                            controller: _host,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.next,
                            decoration: serverFieldDecoration(
                              context,
                              label: 'Host',
                              hint: '192.168.1.10 or nas.local',
                              icon: Icons.lan_outlined,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          flex: 2,
                          child: TvTextField(
                            controller: _port,
                            keyboardType: TextInputType.number,
                            textInputAction:
                                _guest ? TextInputAction.done : TextInputAction.next,
                            decoration: serverFieldDecoration(
                              context,
                              label: 'Port',
                              hint: '445',
                              icon: Icons.settings_ethernet,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: const EdgeInsets.only(top: 4),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      activeThumbColor: theme.colorScheme.primary,
                      title: const Text('Guest — no username/password',
                          style: TextStyle(fontSize: 14)),
                      value: _guest,
                      onChanged: (v) => setState(() => _guest = v),
                    ),
                    if (!_guest) ...[
                      const SizedBox(height: 2),
                      TvTextField(
                        controller: _username,
                        autofillHints: const [AutofillHints.username],
                        textInputAction: TextInputAction.next,
                        decoration: serverFieldDecoration(
                          context,
                          label: 'Username',
                          hint: 'admin',
                          icon: Icons.person_outline,
                        ),
                      ),
                      const SizedBox(height: 14),
                      ServerPasswordField(
                        icon: Icons.lock_outline,
                        controller: _password,
                        label: widget.existing?.hasPassword ?? false
                            ? 'Password (leave empty to keep)'
                            : 'Password',
                        hint: '••••••••',
                      ),
                      const SizedBox(height: 14),
                      TvTextField(
                        controller: _domain,
                        textInputAction: TextInputAction.done,
                        decoration: serverFieldDecoration(
                          context,
                          label: 'Domain',
                          hint: 'WORKGROUP',
                          icon: Icons.account_tree_outlined,
                          optional: true,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_resultMessage != null)
              ServerResultBanner(
                success: _resultSuccess == true,
                message: _resultMessage!,
                margin: const EdgeInsets.fromLTRB(0, 12, 0, 0),
              ),
          ],
        ),
      ),
      actions: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: theme.colorScheme.outline),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _testing ? null : _test,
          icon: _testing
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.wifi_tethering, size: 16),
          label: const Text('Test'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _save,
          icon: const Icon(Icons.check_rounded, size: 16),
          label: const Text('Save'),
        ),
      ],
    );
  }
}
