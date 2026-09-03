import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/library_folders.dart';
import '../services/tmdb_client.dart';
import '../services/webdav_client.dart';
import '../utils/file_info_extractor.dart';
import '../widgets/server_form_kit.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/tv_text_field.dart';
import '../widgets/tv_tile.dart';
import 'tmd_details_screen.dart';

enum _WebDavProtocol { http, https }

/// Percent-encodes each path segment of a WebDAV file path so playback URLs
/// survive filenames with spaces, `#`, `%`, `?`, or non-ASCII characters
/// (a raw `#` would otherwise truncate the URL as a fragment).
String _encodePath(String path) =>
    path.split('/').map(Uri.encodeComponent).join('/');

/// WebDAV browser: saved servers -> folders -> videos. Playback streams the
/// plain HTTP file URL to the player with the server's Basic auth header.
class WebDavScreen extends StatefulWidget {
  const WebDavScreen({super.key});

  @override
  State<WebDavScreen> createState() => _WebDavScreenState();
}

class _WebDavScreenState extends State<WebDavScreen> {
  static final WebDavClient _webdav = WebDavClient.instance;
  static final _epPattern = RegExp(
      r'\b(?:S\d{1,2}E\d{1,2}|\d{1,2}x\d{1,3}|E(?:P)?\d{1,3})\b|\[(\d{1,3})\]',
      caseSensitive: false);

  List<WebDavServer> _servers = const [];
  WebDavServer? _browsing;
  String _path = '/';
  List<WebDavEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  bool _isSeriesFolder = false;

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

  Future<void> _loadServers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final servers = await _webdav.listServers();
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

  Future<void> _openServer(WebDavServer server) async {
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
      final entries = await _webdav.listDirectory(server.id, path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _entries = entries;
        _loading = false;
      });
      _prefetchTmdbMeta(entries);
      _detectAndLoadSeriesFolder(entries);
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
    await _webdav.invalidateListingCache(url: server.url);
    await _loadDirectory(_path);
  }

  /// Best-effort TMDB prefetch for the current folder's video files.
  void _prefetchTmdbMeta(List<WebDavEntry> entries) {
    final server = _browsing;
    if (server == null) return;
    final service = TmdService.instance;
    for (final entry in entries) {
      if (entry.isDirectory) continue;
      service.resolve(VideoItem(
        id: 'webdav_${server.id}${entry.path}',
        title: entry.name,
        uri: '',
        resumeKey: 'webdav_${server.id}${entry.path}',
        duration: Duration.zero,
        sizeBytes: entry.size,
      )).catchError((_) => null as TmdMeta?);
    }
  }

  /// Detect TV series folder + fetch TMDB header metadata (Nova-style).
  Future<void> _detectAndLoadSeriesFolder(List<WebDavEntry> entries) async {
    final server = _browsing;
    if (server == null) return;
    final videos = entries.where((e) => !e.isDirectory).toList();
    if (videos.isEmpty) return;
    final episodes = videos
        .where((e) => ParsedFileName.parse(e.name).isEpisode || _epPattern.hasMatch(e.name))
        .toList();
    if (episodes.isEmpty) return;
    // Only trigger series view for ≥2 episodes (same as SMB screen).
    if (episodes.length < 2) return;
    final cleanPath = _path.replaceAll(RegExp(r'/+$'), '');
    final folderName = cleanPath.isEmpty
        ? server.name
        : cleanPath.split('/').where((s) => s.isNotEmpty).last;
    final metadataKey = 'webdav_folder:${server.id}$cleanPath';
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

  Future<void> _openEntry(WebDavEntry entry) async {
    if (entry.isDirectory) {
      await _loadDirectory(entry.path);
      return;
    }
    final server = _browsing;
    if (server == null) return;

    String authHeader;
    try {
      authHeader = await _webdav.authorizationHeader(server.id);
    } on PlatformException {
      authHeader = '';
    }
    if (!mounted) return;

    final base = server.url.replaceAll(RegExp(r'/+$'), '');
    // Playlist = every video in this folder; used to find the tapped entry.
    final videos = _entries.where((e) => !e.isDirectory).toList();
    final playlist = [
      for (final v in videos)
        () {
          final fi = extractFileInfo(v.name);
          return VideoItem(
            id: 'webdav_${server.id}${v.path}',
            title: v.name,
            uri: '$base${_encodePath(v.path)}',
            // WebDAV URLs are stable across sessions; key resume on them.
            resumeKey: 'webdav_${server.id}${v.path}',
            duration: Duration.zero,
            sizeBytes: v.size,
            httpHeaders: authHeader.isEmpty
                ? const {}
                : {'Authorization': authHeader},
            allowSelfSigned: server.allowSelfSigned,
            webdavServerId: server.id,
            videoCodec: fi.videoCodec,
            audioCodec: fi.audioCodec,
            audioChannels: fi.audioChannels,
            resolution: fi.resolution,
            hdrHint: fi.hdrHint,
          );
        }(),
    ];
    final playIndex = playlist.indexWhere((item) => item.title == entry.name);
    if (playIndex < 0 || playlist.isEmpty) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: playlist[playIndex],
          parentMetadataKey: _isSeriesFolder
              ? 'webdav_folder:${server.id}${_path.replaceAll(RegExp(r'/+$'), '')}'
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

  Future<void> _bookmarkCurrentFolder() async {
    final server = _browsing;
    if (server == null || _atBrowseRoot) return;
    final cleanPath = _path.replaceAll(RegExp(r'/+$'), '');
    final folderName = cleanPath.split('/').last;
    final id = 'webdav_${server.id}_${cleanPath.hashCode}';
    final folder = LibraryFolder(
      id: id,
      name: folderName,
      path: 'webdav:${server.id}$cleanPath',
      addedAt: DateTime.now(),
      source: LibraryFolderSource.webdav,
      networkServerId: server.id,
      networkPath: cleanPath,
      networkLabel: server.name,
    );
    await LibraryFoldersStore.add(folder);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bookmarked $folderName to Home (WebDAV · ${server.name})')),
      );
    }
  }

  void _addServer() => _showServerDialog();

  void _editServer(WebDavServer server) => _showServerDialog(existing: server);

  Future<void> _deleteServer(WebDavServer server) async {
    await _webdav.deleteServer(server.id);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Removed ${server.name}')));
    _loadServers();
  }

  void _showServerDialog({WebDavServer? existing}) {
    showDialog<void>(
      context: context,
      builder: (_) =>
          _ServerFormDialog(existing: existing, onSave: () => _loadServers()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final browsing = _browsing;
    return Scaffold(
      appBar: AppBar(
        title: Text(browsing == null ? 'WebDAV' : _breadcrumbTitle(browsing)),
        leading: browsing != null
            ? IconButton(
                tooltip: 'Up',
                icon: const Icon(Icons.arrow_back),
                onPressed: _goUp,
              )
            : null,
        actions: [
          if (browsing != null && !_atBrowseRoot)
            IconButton(
              tooltip: 'Bookmark this folder to Home',
              icon: const Icon(Icons.bookmark_add_outlined),
              onPressed: _bookmarkCurrentFolder,
            ),
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
                  heroTag: 'webdav_refresh',
                  onPressed: _loadServers,
                  tooltip: 'Refresh',
                  child: const Icon(Icons.refresh),
                ),
                const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'webdav_add',
                  onPressed: _addServer,
                  tooltip: 'Add server',
                  child: const Icon(Icons.add),
                ),
              ],
            )
          : null,
      body: TvOverscan(child: _body(context)),
    );
  }

  String _breadcrumbTitle(WebDavServer server) {
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
              : TmdService.instance
                  .metaFor('webdav_${server.id}${entry.path}');
          return _WebDavTile(entry: entry, tmdbMeta: meta, onTap: () => _openEntry(entry));
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
              leading: const Icon(Icons.cloud),
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

class _WebDavTile extends StatelessWidget {
  const _WebDavTile({
    required this.entry,
    required this.tmdbMeta,
    required this.onTap,
  });

  final WebDavEntry entry;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;

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
      trailing: entry.isDirectory ? const Icon(Icons.chevron_right) : null,
      onTap: onTap,
    );
  }
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

class _ServerFormDialog extends StatefulWidget {
  const _ServerFormDialog({this.existing, this.onSave});

  final WebDavServer? existing;
  final VoidCallback? onSave;

  @override
  State<_ServerFormDialog> createState() => _ServerFormDialogState();
}

class _ServerFormDialogState extends State<_ServerFormDialog> {
  static final WebDavClient _webdav = WebDavClient.instance;

  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _path;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late _WebDavProtocol _protocol;
  late bool _allowSelfSigned;
  bool _testing = false;
  String? _resultMessage;
  bool? _resultSuccess;

  bool get _isHttps => _protocol == _WebDavProtocol.https;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _name = TextEditingController(text: s?.name ?? '');
    _username = TextEditingController(text: s?.username ?? '');
    _password = TextEditingController(text: '');
    _allowSelfSigned = s?.allowSelfSigned ?? false;

    // Prefill host/port/path from an existing server URL so editing stays
    // round-trip clean.
    final uri = s == null ? null : Uri.tryParse(s.url);
    if (uri != null && uri.host.isNotEmpty) {
      _protocol = uri.scheme == 'https'
          ? _WebDavProtocol.https
          : _WebDavProtocol.http;
      _host = TextEditingController(text: uri.host);
      _port = TextEditingController(
        text: (uri.hasPort ? uri.port : (_isHttps ? 443 : 80)).toString(),
      );
      final p = uri.path.isEmpty || uri.path == '/' ? '' : uri.path;
      _path = TextEditingController(text: p.replaceAll(RegExp(r'/+$'), ''));
    } else {
      _protocol = _WebDavProtocol.http;
      _host = TextEditingController();
      _port = TextEditingController();
      _path = TextEditingController();
    }
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

  void _setProtocol(_WebDavProtocol p) {
    setState(() {
      // Fill the protocol's default port only when the field is empty (fresh
      // form) or still holds the other protocol's auto-default from a toggle,
      // so a typed custom port is preserved.
      final current = _port.text.trim();
      final staleDefault = p == _WebDavProtocol.http ? '8443' : '8080';
      _protocol = p;
      if (current.isEmpty || current == staleDefault) {
        _port.text = p == _WebDavProtocol.http ? '8080' : '8443';
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

  /// Builds `scheme://host:port/path` from the split fields.
  String _composedUrl() {
    final scheme = _isHttps ? 'https' : 'http';
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final path = _path.text.trim();
    var url = port == null ? '$scheme://$host' : '$scheme://$host:$port';
    if (path.isNotEmpty && path != '/') {
      url += path.startsWith('/') ? path : '/$path';
    }
    return url.replaceAll(RegExp(r'/+$'), '');
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
    final result = await _webdav.testConnection(
      url: _composedUrl(),
      username: _username.text.trim(),
      password: _password.text,
      allowSelfSigned: _allowSelfSigned,
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
      await _webdav.saveServer(
        id: widget.existing?.id,
        name: _name.text.trim(),
        url: _composedUrl(),
        username: _username.text.trim(),
        password: _password.text,
        allowSelfSigned: _allowSelfSigned,
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
        subtitle: 'WebDAV',
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
                    // Protocol segmented choice.
                    Row(
                      children: [
                        Expanded(
                          child: _protocolChoice(
                            context,
                            icon: Icons.language,
                            label: 'HTTP',
                            selected: !_isHttps,
                            onTap: () => _setProtocol(_WebDavProtocol.http),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _protocolChoice(
                            context,
                            icon: Icons.lock_outline,
                            label: 'HTTPS',
                            selected: _isHttps,
                            onTap: () => _setProtocol(_WebDavProtocol.https),
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
                              hint: '8080',
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
                              hint: '/dav',
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
                    if (!_isHttps &&
                        (_username.text.trim().isNotEmpty ||
                            _password.text.isNotEmpty))
                      ServerResultBanner(
                        success: false,
                        margin: const EdgeInsets.only(top: 10),
                        message: 'HTTP sends the password insecurely. Use '
                            'HTTPS when connecting over the internet.',
                      ),
                    if (_isHttps)
                      SwitchListTile(
                        contentPadding: const EdgeInsets.only(top: 4),
                        controlAffinity: ListTileControlAffinity.leading,
                        dense: true,
                        activeThumbColor: theme.colorScheme.primary,
                        title: const Text('Self-signed certificate',
                            style: TextStyle(fontSize: 14)),
                        subtitle: const Text(
                          'Trust HTTPS servers without a CA certificate '
                          '(NAS, Nextcloud, etc.)',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: _allowSelfSigned,
                        onChanged: (v) => setState(() => _allowSelfSigned = v),
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

  /// One half of the HTTP/HTTPS segmented protocol picker.
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
