import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/ftp_client.dart';
import '../services/tmdb_client.dart';
import '../services/watched_store.dart';
import '../utils/file_info_extractor.dart';
import '../widgets/server_form_kit.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/tv_text_field.dart';
import '../widgets/tv_tile.dart';
import 'tmd_details_screen.dart';

enum _FtpProtocol { ftp, sftp }

/// FTP / SFTP browser: saved servers -> folders -> videos. Playback streams
/// via a custom ExoPlayer DataSource (FtpDataSource) that wraps
/// Apache Commons Net (FTP) or JSch (SFTP) with seek via REST / SFTP resume.
class FtpScreen extends StatefulWidget {
  const FtpScreen({super.key});

  @override
  State<FtpScreen> createState() => _FtpScreenState();
}

class _FtpScreenState extends State<FtpScreen> {
  static final FtpClient _ftp = FtpClient.instance;
  static final _epPattern = RegExp(
      r'\b(?:S\d{1,2}E\d{1,2}|\d{1,2}x\d{1,3}|E(?:P)?\d{1,3})\b|\[(\d{1,3})\]',
      caseSensitive: false);

  List<FtpServer> _servers = const [];
  FtpServer? _browsing;
  String _path = '/';
  List<FtpEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  bool _isSeriesFolder = false;

  /// Watched marks for the current folder, keyed by the same stable resume
  /// key each video uses for playback.
  Set<String> _watchedKeys = {};

  bool get _atBrowseRoot => _browsing == null || _path == '/';

  @override
  void initState() {
    super.initState();
    TmdService.instance.addListener(_onMetadataChanged);
    _loadServers();
  }

  @override
  void dispose() {
    TmdService.instance.removeListener(_onMetadataChanged);
    super.dispose();
  }

  void _onMetadataChanged() {
    if (mounted) setState(() {});
  }

  String _watchedKeyFor(FtpEntry entry) {
    final server = _browsing;
    if (server == null || entry.isDirectory) return '';
    return 'ftp_${server.id}${entry.path}';
  }

  Future<void> _refreshWatched() async {
    try {
      final watched = await WatchedStore.load();
      if (mounted) setState(() => _watchedKeys = watched);
    } catch (_) {}
  }

  Future<void> _toggleWatched(FtpEntry entry) async {
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

  Future<void> _loadServers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final servers = await _ftp.listServers();
      if (!mounted) return;
      setState(() {
        _servers = servers;
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

  Future<void> _openServer(FtpServer server) async {
    setState(() {
      _browsing = server;
      _path = '/';
      _loading = true;
      _error = null;
    });
    await _loadDirectory('/');
  }

  Future<void> _loadDirectory(String path) async {
    final server = _browsing;
    if (server == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _isSeriesFolder = false;
    });
    try {
      final entries = await _ftp.listDirectory(server.id, path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _entries = entries;
        _loading = false;
      });
      _prefetchTmdbMeta(entries);
      _detectAndLoadSeriesFolder(entries);
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

  Future<void> _onRefresh() async {
    final server = _browsing;
    if (server == null) return;
    await _ftp.invalidateListingCache(id: server.id);
    await _loadDirectory(_path);
  }

  /// Best-effort TMDB prefetch for the current folder's video files.
  void _prefetchTmdbMeta(List<FtpEntry> entries) {
    final server = _browsing;
    if (server == null) return;
    final service = TmdService.instance;
    for (final entry in entries) {
      if (entry.isDirectory) continue;
      service.resolve(VideoItem(
        id: 'ftp_${server.id}${entry.path}',
        title: entry.name,
        uri: '',
        resumeKey: 'ftp_${server.id}${entry.path}',
        duration: Duration.zero,
        sizeBytes: entry.size,
      )).catchError((_) => null as TmdMeta?);
    }
  }

  /// Detect TV series folder + fetch TMDB header metadata (Nova-style).
  Future<void> _detectAndLoadSeriesFolder(List<FtpEntry> entries) async {
    final server = _browsing;
    if (server == null) return;
    final videos = entries.where((e) => !e.isDirectory).toList();
    if (videos.isEmpty) return;
    final episodes = videos
        .where((e) => ParsedFileName.parse(e.name).isEpisode || _epPattern.hasMatch(e.name))
        .toList();
    if (episodes.isEmpty) return;
    if (episodes.length < 2) return;
    final cleanPath = _path.replaceAll(RegExp(r'/+$'), '');
    final folderName = cleanPath.isEmpty
        ? server.name
        : cleanPath.split('/').where((s) => s.isNotEmpty).last;
    final metadataKey = 'ftp_folder:${server.id}$cleanPath';
    final service = TmdService.instance;
    await service.ensureLoaded();
    final meta = service.metaFor(metadataKey) ??
        await service.resolveFolder(metadataKey, folderName);
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

  Future<void> _openEntry(FtpEntry entry) async {
    if (entry.isDirectory) {
      await _loadDirectory(entry.path);
      return;
    }
    final server = _browsing;
    if (server == null) return;

    final scheme = server.isSftp ? 'sftp' : 'ftp';
    final encodedPath = entry.path.split('/').map(Uri.encodeComponent).join('/');
    // FtpDataSource resolves ftp://<serverId>/<path> to saved credentials.
    final uri = '$scheme://${server.id}$encodedPath';

    final fi = extractFileInfo(entry.name);
    final item = VideoItem(
      id: 'ftp_${server.id}${entry.path}',
      title: entry.name,
      uri: uri,
      resumeKey: 'ftp_${server.id}${entry.path}',
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
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: item,
          parentMetadataKey: _isSeriesFolder
              ? 'ftp_folder:${server.id}${_path.replaceAll(RegExp(r'/+$'), '')}'
              : null,
        ),
      ),
    );
  }

  Future<void> _goUp() async {
    if (_browsing == null) {
      Navigator.of(context).pop();
      return;
    }
    if (_path != '/') {
      final trimmed = _path.replaceAll(RegExp(r'/+$'), '');
      final slash = trimmed.lastIndexOf('/');
      await _loadDirectory(slash <= 0 ? '/' : trimmed.substring(0, slash));
    } else {
      setState(() {
        _browsing = null;
        _path = '/';
        _loading = false;
      });
      await _loadServers();
    }
  }

  void _addServer() => _showServerDialog();

  void _editServer(FtpServer server) => _showServerDialog(existing: server);

  Future<void> _deleteServer(FtpServer server) async {
    await _ftp.deleteServer(server.id);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Removed ${server.name}')));
    _loadServers();
  }

  void _showServerDialog({FtpServer? existing}) {
    showDialog<void>(
      context: context,
      builder: (_) =>
          _ServerFormDialog(existing: existing, onSave: () => _loadServers()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final browsing = _browsing;
    return PopScope(
      canPop: browsing == null,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _goUp();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(browsing == null ? 'FTP / SFTP' : _breadcrumbTitle(browsing)),
        leading: browsing != null
            ? IconButton(
                tooltip: 'Up',
                icon: const Icon(Icons.arrow_back),
                onPressed: _goUp,
              )
            : null,
        actions: [
          if (browsing != null)
            IconButton(
              tooltip: 'Server list',
              icon: const Icon(Icons.dns_outlined),
              onPressed: () => setState(() {
                _browsing = null;
                _path = '/';
                _loading = false;
              }),
            ),
        ],
      ),
      floatingActionButton: browsing == null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton(
                  heroTag: 'ftp_refresh',
                  onPressed: _loadServers,
                  tooltip: 'Refresh',
                  child: const Icon(Icons.refresh),
                ),
                const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'ftp_add',
                  onPressed: _addServer,
                  tooltip: 'Add server',
                  child: const Icon(Icons.add),
                ),
              ],
            )
          : null,
      body: TvOverscan(child: _body(context)),
    ),
    );
  }

  String _breadcrumbTitle(FtpServer server) {
    if (_path == '/') return server.name;
    final folder = _path.replaceAll(RegExp(r'/+$'), '').split('/').last;
    return '${server.name} / $folder';
  }

  Widget _body(BuildContext context) {
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
              Text(
                'Error: $_error',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
      return RefreshIndicator(
        onRefresh: _onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Nothing here',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final entry = _entries[index];
          final server = _browsing;
          final meta = entry.isDirectory || server == null
              ? null
              : TmdService.instance.metaFor('ftp_${server.id}${entry.path}');
          return _FtpTile(
            entry: entry,
            tmdbMeta: meta,
            watched: !entry.isDirectory &&
                _watchedKeys.contains(_watchedKeyFor(entry)),
            onToggleWatched:
                entry.isDirectory ? null : () => _toggleWatched(entry),
            onTap: () => _openEntry(entry),
          );
        },
      ),
    );
  }

  Widget _serverList(BuildContext context) {
    if (_servers.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_outlined, size: 48, color: Colors.white38),
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
          const _SectionHeader('Saved servers'),
          for (final server in _servers)
            TvTile(
              leading: Icon(server.isSftp ? Icons.lock_outline : Icons.folder_outlined),
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
            ),
        ],
      ),
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

class _FtpTile extends StatelessWidget {
  const _FtpTile({
    required this.entry,
    required this.tmdbMeta,
    required this.onTap,
    this.watched = false,
    this.onToggleWatched,
  });

  final FtpEntry entry;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;
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
    final icon = entry.isDirectory ? Icons.folder : Icons.play_circle_outline;
    final color = entry.isDirectory
        ? colorScheme.primary
        : colorScheme.secondary;
    final subtitle = entry.isDirectory ? null : _sizeLabel(entry.size);
    final posterUrl = posterUrlOf(tmdbMeta);
    return TvTile(
      leading: posterUrl != null
          ? _Poster(posterUrl: posterUrl)
          : Icon(icon, color: color),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onToggleWatched != null)
            IconButton(
              tooltip: watched ? 'Mark as unwatched' : 'Mark as watched',
              icon: Icon(
                watched ? Icons.check_circle : Icons.check_circle_outline,
                color: watched
                    ? Colors.green.shade400
                    : colorScheme.onSurfaceVariant,
              ),
              onPressed: onToggleWatched,
            ),
          if (entry.isDirectory) const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
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
          Icons.play_circle_outline,
          color: Theme.of(context).colorScheme.secondary,
        ),
      ),
    );
  }
}

class _ServerFormDialog extends StatefulWidget {
  const _ServerFormDialog({this.existing, this.onSave});

  final FtpServer? existing;
  final VoidCallback? onSave;

  @override
  State<_ServerFormDialog> createState() => _ServerFormDialogState();
}

class _ServerFormDialogState extends State<_ServerFormDialog> {
  static final FtpClient _ftp = FtpClient.instance;

  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _path;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late _FtpProtocol _protocol;
  bool _testing = false;
  String? _resultMessage;
  bool? _resultSuccess;

  bool get _isSftp => _protocol == _FtpProtocol.sftp;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _name = TextEditingController(text: s?.name ?? '');
    _host = TextEditingController(text: s?.host ?? '');
    _path = TextEditingController(text: _stripSlash(s?.path ?? ''));
    _username = TextEditingController(text: s?.username ?? '');
    _password = TextEditingController(text: '');
    _protocol = (s?.isSftp ?? false) ? _FtpProtocol.sftp : _FtpProtocol.ftp;
    final defaultPort = _isSftp ? 22 : 21;
    _port = TextEditingController(
      text: s != null ? s.port.toString() : defaultPort.toString(),
    );
  }

  static String _stripSlash(String p) {
    if (p == '/' || p.isEmpty) return '';
    return p.replaceAll(RegExp(r'/+$'), '');
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _path.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _setProtocol(_FtpProtocol p) {
    setState(() {
      final current = _port.text.trim();
      final staleDefault = p == _FtpProtocol.ftp ? '22' : '21';
      _protocol = p;
      if (current.isEmpty || current == staleDefault) {
        _port.text = p == _FtpProtocol.ftp ? '21' : '22';
      }
    });
  }

  String? _validate() {
    if (_host.text.trim().isEmpty) return 'Host is required';
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      return 'Enter a valid port (1–65535)';
    }
    return null;
  }

  String _normalizedPath() {
    final p = _path.text.trim();
    if (p.isEmpty || p == '/') return '/';
    return p.startsWith('/') ? p : '/$p';
  }

  Future<void> _test() async {
    final error = _validate();
    if (error != null) {
      setState(() {
        _resultSuccess = false;
        _resultMessage = error;
      });
      return;
    }
    setState(() {
      _testing = true;
      _resultMessage = null;
      _resultSuccess = null;
    });
    final result = await _ftp.testConnection(
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? (_isSftp ? 22 : 21),
      path: _normalizedPath(),
      username: _username.text.trim(),
      password: _password.text,
      isSftp: _isSftp,
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _resultSuccess = result.ok;
      _resultMessage = result.ok
          ? 'Connected'
          : (result.error ?? 'Connection failed');
    });
  }

  Future<void> _save() async {
    final error = _validate();
    if (error != null) {
      setState(() {
        _resultSuccess = false;
        _resultMessage = error;
      });
      return;
    }
    try {
      await _ftp.saveServer(
        id: widget.existing?.id,
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? (_isSftp ? 22 : 21),
        path: _normalizedPath(),
        username: _username.text.trim(),
        password: _password.text,
        isSftp: _isSftp,
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
        subtitle: 'FTP / SFTP',
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
                        label: 'Server name',
                        hint: 'e.g. Home NAS',
                        icon: Icons.badge_outlined,
                        optional: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _protocolChoice(
                            context,
                            icon: Icons.folder_outlined,
                            label: 'FTP',
                            selected: !_isSftp,
                            onTap: () => _setProtocol(_FtpProtocol.ftp),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _protocolChoice(
                            context,
                            icon: Icons.lock_outline,
                            label: 'SFTP',
                            selected: _isSftp,
                            onTap: () => _setProtocol(_FtpProtocol.sftp),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    TvTextField(
                      controller: _host,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      decoration: serverFieldDecoration(
                        context,
                        label: 'Host',
                        hint: '192.168.1.16 or nas.local',
                        icon: Icons.lan_outlined,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 2,
                          child: TvTextField(
                            controller: _port,
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.next,
                            decoration: serverFieldDecoration(
                              context,
                              label: 'Port',
                              hint: _isSftp ? '22' : '21',
                              icon: Icons.settings_ethernet,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          flex: 3,
                          child: TvTextField(
                            controller: _path,
                            textInputAction: TextInputAction.next,
                            decoration: serverFieldDecoration(
                              context,
                              label: 'Path',
                              hint: '/',
                              icon: Icons.folder_open_outlined,
                              optional: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    TvTextField(
                      controller: _username,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      decoration: serverFieldDecoration(
                        context,
                        label: 'Username',
                        hint: 'admin',
                        icon: Icons.person_outline,
                        optional: true,
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
                    if (!_isSftp &&
                        (_username.text.trim().isNotEmpty ||
                            _password.text.isNotEmpty))
                      const ServerResultBanner(
                        success: false,
                        margin: EdgeInsets.only(top: 10),
                        message:
                            'FTP sends credentials and data unencrypted. Use SFTP when connecting over the internet.',
                      ),
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

  Widget _protocolChoice(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : theme.colorScheme.outline;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color, width: selected ? 1.4 : 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
                color: selected ? theme.colorScheme.primary : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
