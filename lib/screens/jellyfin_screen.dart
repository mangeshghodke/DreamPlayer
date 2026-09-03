import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/tmdb_client.dart';
import '../widgets/server_form_kit.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/tv_tile.dart';
import 'tmd_details_screen.dart';

/// Jellyfin / Emby browser: saved + discovered servers -> libraries -> folders
/// -> play. Playback streams the direct-play URL (token as `api_key` query
/// param) through the existing HTTP data sources on both platforms.
class JellyfinScreen extends StatefulWidget {
  const JellyfinScreen({super.key});

  @override
  State<JellyfinScreen> createState() => _JellyfinScreenState();
}

/// One level of the browse breadcrumb: the folder's display title and the
/// parent id used to load its children (empty stack = top-level libraries).
class _Crumb {
  const _Crumb(this.title, this.parentId);

  final String title;
  final String parentId;
}

class _JellyfinScreenState extends State<JellyfinScreen> {
  final JellyfinClient _client = JellyfinClient();

  List<JellyfinServer> _servers = const [];
  List<JellyfinServer> _discovered = const [];
  bool _scanning = false;

  JellyfinServer? _browsing;
  List<_Crumb> _crumbs = const [];
  List<JellyfinItem> _items = const [];
  bool _loading = true;
  String? _error;

  bool get _atBrowseRoot => _browsing == null;

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
    final servers = await _client.loadServers();
    if (!mounted) return;
    setState(() {
      _servers = servers;
      _loading = false;
    });
  }

  Future<void> _scanNetwork() async {
    setState(() {
      _scanning = true;
      _discovered = const [];
    });
    final found = await _client.discoverServers();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _discovered = found;
    });
  }

  // ---------------------------------------------------------------------------
  // Browsing
  // ---------------------------------------------------------------------------

  Future<void> _openServer(JellyfinServer server) async {
    if (!server.isAuthenticated) {
      final loggedIn = await _login(server);
      if (!mounted || loggedIn == null) return;
      server = loggedIn;
    }
    setState(() {
      _browsing = server;
      _crumbs = const [];
      _loading = true;
      _error = null;
    });
    await _loadLevel();
  }

  Future<void> _loadLevel() async {
    final server = _browsing;
    if (server == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = _crumbs.isEmpty
          ? await _client.getLibraries(server)
          : await _client.getItems(server, _crumbs.last.parentId);
      if (!mounted) return;
      // Folders first, then playables, each sorted by name.
      final folders = items.where((i) => i.isFolder).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final playables = items.where((i) => i.isPlayable).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _items = [...folders, ...playables];
        _loading = false;
      });
    } on JellyfinException catch (e) {
      if (!mounted) return;
      if (e.message.contains('Session expired')) {
        await _handleSessionExpired();
      } else {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = JellyfinClient.friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<void> _onRefresh() async {
    final server = _browsing;
    if (server == null) return;
    await _loadLevel();
  }

  /// Best-effort TMDB prefetch for the current level's playables. Each item
  /// resolves under the SAME stable key its tap uses ([_client.resumeKey]), so

  /// Cached TMDB meta for a playable row, looked up under the same identity key
  /// its tap uses so the poster and the opened details screen agree.
  TmdMeta? _tmdbFor(JellyfinItem item) {
    final server = _browsing;
    if (server == null || item.isFolder) return null;
    return TmdService.instance
        .metaFor(_client.resumeKey(server, item));
  }

  Future<void> _handleSessionExpired() async {
    final server = _browsing;
    if (server == null) return;
    // Drop the dead token so the login dialog starts clean.
    final updated = server.copyWith(token: null, userId: null);
    await _replaceServer(updated);
    if (!mounted) return;
    final loggedIn = await _login(updated);
    if (!mounted || loggedIn == null) return;
    setState(() => _browsing = loggedIn);
    await _loadLevel();
  }

  Future<void> _openItem(JellyfinItem item) async {
    if (item.isFolder) {
      setState(() {
        _crumbs = [..._crumbs, _Crumb(item.name, item.id)];
        _loading = true;
      });
      await _loadLevel();
      return;
    }
    final server = _browsing;
    if (server == null || !item.isPlayable) return;
    final playables = _items.where((i) => i.isPlayable).toList();
    final List<VideoItem> playlist = [
      for (final playable in playables) _client.videoItem(server, playable),
    ];
    final playIndex = playlist.indexWhere((video) => video.title == item.name);
    if (playIndex < 0 || playlist.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          video: playlist[playIndex],
          // Pass the parent folder's metadata key so the details screen
          // reuses cached TMDB metadata instead of re-resolving from scratch.
          parentMetadataKey: _crumbs.isNotEmpty
              ? _client.resumeKey(server, item)
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
    if (_crumbs.isNotEmpty) {
      setState(() {
        _crumbs = _crumbs.sublist(0, _crumbs.length - 1);
        _loading = true;
      });
      await _loadLevel();
    } else {
      setState(() {
        _browsing = null;
        _crumbs = const [];
        _loading = false;
      });
      await _loadServers();
    }
  }

  /// Adds the currently browsed folder (a TV-show/library folder) to the home
  /// library. The server URL + item id are persisted; the token is never — the
  /// entry is re-matched against the saved servers each time it's opened, so it
  /// keeps working across logins.
  Future<void> _addToLibrary(JellyfinItem item) async {
    final server = _browsing;
    if (server == null) return;
    final folder = LibraryFolder(
      id: 'jellyfin_folder_${server.urlHost}_${item.id}',
      name: item.name,
      path: 'jellyfin:${item.id}',
      addedAt: DateTime.now(),
      source: LibraryFolderSource.jellyfin,
      jellyfinServerUrl: server.url,
      jellyfinItemId: item.id,
    );
    await LibraryFoldersStore.add(folder);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${item.name}" added to your library')),
    );
    // Fetch the series' own info from the server in the background so the home
    // card + details screen have the main poster/title/year/overview instantly.
    // Plain folders have no poster (Jellyfin answers with a random child
    // image), so the nearest Series ancestor's info is used instead.
    if (server.isAuthenticated) {
      try {
        final info = await _client.getPrimaryPosterInfo(server, item.id);
        if (info != null) {
          await _client.saveFolderMeta(folder.id, info);
        }
      } catch (_) {
        // Best-effort; the card falls back to the folder name / TMDB lookup.
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Auth + server persistence
  // ---------------------------------------------------------------------------

  /// Prompts for username/password, authenticates, persists, returns the
  /// signed-in server (null if cancelled).
  Future<JellyfinServer?> _login(JellyfinServer server) async {
    final result = await showDialog<({String username, String password})>(
      context: context,
      builder: (_) => _LoginDialog(
        serverName: server.name,
        url: server.url,
        username: server.username,
        allowSelfSigned: server.allowSelfSigned,
      ),
    );
    if (result == null) return null;
    try {
      final authed = await _client.authenticate(
        server,
        username: result.username,
        password: result.password,
      );
      await _replaceServer(authed);
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Signed in to ${authed.name}')),
      );
      return authed;
    } on Exception catch (e) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(JellyfinClient.friendlyError(e))),
      );
      return null;
    }
  }

  Future<void> _replaceServer(JellyfinServer updated) async {
    final index = _servers.indexWhere((s) => s.url == updated.url);
    final servers = [..._servers];
    if (index >= 0) {
      servers[index] = updated;
    } else {
      servers.add(updated);
    }
    setState(() => _servers = servers);
    await _client.saveServers(servers);
  }

  Future<void> _deleteServer(JellyfinServer server) async {
    final servers = _servers.where((s) => s.url != server.url).toList();
    setState(() => _servers = servers);
    await _client.saveServers(servers);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Removed ${server.name}')));
  }

  void _addServer() => _showServerDialog();

  void _editServer(JellyfinServer server) => _showServerDialog(existing: server);

  void _showServerDialog({JellyfinServer? existing}) {
    showDialog<void>(
      context: context,
      builder: (_) => _ServerFormDialog(existing: existing, onSave: _loadServers),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final browsing = _browsing;
    return Scaffold(
      appBar: AppBar(
        title: Text(browsing == null ? 'Jellyfin' : _breadcrumbTitle(browsing)),
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
                _crumbs = const [];
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
                    heroTag: 'jellyfin_scan',
                    onPressed: _scanNetwork,
                    tooltip: 'Scan network',
                    child: const Icon(Icons.wifi_find),
                  ),
                const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'jellyfin_refresh',
                  onPressed: _loadServers,
                  tooltip: 'Refresh',
                  child: const Icon(Icons.refresh),
                ),
                const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'jellyfin_add',
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

  String _breadcrumbTitle(JellyfinServer server) {
    if (_crumbs.isEmpty) return server.name;
    return '${server.name} / ${_crumbs.last.title}';
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
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
        ),
      );
    }
    if (_browsing == null) return _serverList(context);
    if (_items.isEmpty) {
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
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          return _JellyfinTile(
            item: item,
            tmdbMeta: _tmdbFor(item),
            onTap: () => _openItem(item),
            onAddToLibrary:
                item.isFolder ? () => _addToLibrary(item) : null,
          );
        },
      ),
    );
  }

  Widget _serverList(BuildContext context) {
    if (_servers.isEmpty && _discovered.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.live_tv_outlined, size: 48, color: Colors.white38),
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
              leading: const Icon(Icons.live_tv),
              title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                server.isAuthenticated
                    ? '${server.url} · Signed in as ${server.username}'
                    : '${server.url} · Not signed in',
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
          if (_servers.isNotEmpty || _discovered.isNotEmpty)
            _SectionHeader('On this network'),
          TvTile(
            dense: true,
            leading: const Icon(Icons.wifi_find, size: 20),
            title: Text(_scanning ? 'Scanning\u2026' : 'Scan local network'),
            trailing: _scanning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _scanning ? () {} : _scanNetwork,
            enabled: !_scanning,
          ),
          for (final server in _discovered)
            TvTile(
              leading: const Icon(Icons.radar),
              title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(server.url, maxLines: 1, overflow: TextOverflow.ellipsis),
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

class _JellyfinTile extends StatelessWidget {
  const _JellyfinTile({
    required this.item,
    required this.tmdbMeta,
    required this.onTap,
    this.onAddToLibrary,
  });

  final JellyfinItem item;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;

  /// Shown on folders as a "add to library" shortcut (replaces the plain
  /// chevron so both actions stay reachable).
  final VoidCallback? onAddToLibrary;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = item.isFolder ? Icons.folder : Icons.play_circle_outline;
    final color = item.isFolder ? colorScheme.primary : colorScheme.secondary;
    final subtitle = item.isFolder ? null : item.sizeLabel;
    final posterUrl = posterUrlOf(tmdbMeta);
    return TvTile(
      leading: posterUrl != null
          ? _Poster(posterUrl: posterUrl)
          : Icon(icon, color: color),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: item.isFolder
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onAddToLibrary != null)
                  IconButton(
                    tooltip: 'Add to library',
                    icon: const Icon(Icons.library_add_outlined),
                    onPressed: onAddToLibrary,
                  ),
                const Icon(Icons.chevron_right),
              ],
            )
          : null,
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

/// Add/edit server dialog. Test validates connectivity; Save persists and (when
/// credentials are supplied) authenticates immediately.
class _ServerFormDialog extends StatefulWidget {
  const _ServerFormDialog({this.existing, this.onSave});

  final JellyfinServer? existing;
  final VoidCallback? onSave;

  @override
  State<_ServerFormDialog> createState() => _ServerFormDialogState();
}

class _ServerFormDialogState extends State<_ServerFormDialog> {
  final JellyfinClient _client = JellyfinClient();

  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late bool _allowSelfSigned;
  bool _testing = false;
  String? _resultMessage;
  bool? _resultSuccess;

  JellyfinServer? get _existing => widget.existing;

  @override
  void initState() {
    super.initState();
    final s = _existing;
    _name = TextEditingController(text: s?.name ?? '');
    _url = TextEditingController(text: s?.url ?? '');
    _username = TextEditingController(text: s?.username ?? '');
    _password = TextEditingController(text: '');
    _allowSelfSigned = s?.allowSelfSigned ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  String? _validate() {
    if (JellyfinClient.normalizeUrl(_url.text).isEmpty) {
      return 'Server address is required';
    }
    return null;
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
    try {
      final info = await _client.testConnection(
        _url.text,
        allowSelfSigned: _allowSelfSigned,
      );
      if (!mounted) return;
      // Auto-fill the display name from the server when left blank.
      if (_name.text.trim().isEmpty) _name.text = info.serverName;
      setState(() {
        _testing = false;
        _resultSuccess = true;
        _resultMessage =
            'Connected — ${info.serverName} (${info.version})';
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _resultSuccess = false;
        _resultMessage = JellyfinClient.friendlyError(e);
      });
    }
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
    setState(() {
      _testing = true;
      _resultMessage = null;
      _resultSuccess = null;
    });
    try {
      final info = await _client.testConnection(
        _url.text,
        allowSelfSigned: _allowSelfSigned,
      );
      var server = JellyfinServer(
        name: _name.text.trim().isEmpty ? info.serverName : _name.text.trim(),
        url: JellyfinClient.normalizeUrl(_url.text),
        username: _username.text.trim(),
        token: _existing?.token,
        userId: _existing?.userId,
        allowSelfSigned: _allowSelfSigned,
      );
      // Re-auth when a password was entered (or when none exists yet).
      final password = _password.text;
      if (password.isNotEmpty || server.token == null) {
        if (password.isEmpty) {
          throw const JellyfinException('Enter a password to sign in.');
        }
        server = await _client.authenticate(
          server,
          username: _username.text.trim(),
          password: password,
        );
      }
      final servers = await _client.loadServers();
      final index = servers.indexWhere((s) => s.url == server.url);
      final updated = [...servers];
      if (index >= 0) {
        updated[index] = server;
      } else {
        updated.add(server);
      }
      await _client.saveServers(updated);
      widget.onSave?.call();
      if (mounted) Navigator.of(context).pop();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _resultSuccess = false;
        _resultMessage = JellyfinClient.friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return serverDialog(
      title: ServerDialogTitle(
        icon: _existing == null ? Icons.add_link : Icons.dns_outlined,
        title: _existing == null ? 'Add server' : 'Edit server',
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
                    ServerTextField(
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      decoration: serverFieldDecoration(
                        context,
                        label: 'Server name',
                        hint: 'e.g. Home Jellyfin',
                        icon: Icons.badge_outlined,
                        optional: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    ServerTextField(
                      controller: _url,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      decoration: serverFieldDecoration(
                        context,
                        label: 'Server address',
                        hint: 'http://192.168.1.16:8096',
                        icon: Icons.lan_outlined,
                      ),
                    ),
                    const SizedBox(height: 14),
                    ServerTextField(
                      controller: _username,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
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
                      label: _existing?.token != null
                          ? 'Password (leave empty to keep)'
                          : 'Password',
                      hint: '••••••••',
                    ),
                    SwitchListTile(
                      contentPadding: const EdgeInsets.only(top: 4),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      activeThumbColor: theme.colorScheme.primary,
                      title: const Text('Self-signed certificate',
                          style: TextStyle(fontSize: 14)),
                      subtitle: const Text(
                        'Trust HTTPS servers without a CA certificate',
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
                margin: const EdgeInsets.fromLTRB(0, 12, 0, 12),
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
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
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
          onPressed: _testing ? null : _save,
          icon: const Icon(Icons.check_rounded, size: 16),
          label: const Text('Save'),
        ),
      ],
    );
  }
}

/// Username + password prompt for a server with no (or expired) token.
class _LoginDialog extends StatefulWidget {
  const _LoginDialog({
    required this.serverName,
    required this.url,
    this.username = '',
    required this.allowSelfSigned,
  });

  final String serverName;
  final String url;
  final String username;
  final bool allowSelfSigned;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  late final TextEditingController _username;
  late final TextEditingController _password;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _username = TextEditingController(text: widget.username);
    _password = TextEditingController();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final username = _username.text.trim();
    if (username.isEmpty) {
      setState(() {
        _busy = false;
        _error = 'Enter your username.';
      });
      return;
    }
    if (_password.text.isEmpty) {
      setState(() {
        _busy = false;
        _error = 'Enter your password.';
      });
      return;
    }
    Navigator.of(context).pop((username: username, password: _password.text));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return serverDialog(
      title: ServerDialogTitle(
        icon: Icons.login_rounded,
        title: 'Sign in',
        subtitle: widget.serverName,
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.dns_outlined,
                        size: 15, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.url,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              ServerTextField(
                controller: _username,
                autofocus: true,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.username],
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
                label: 'Password',
                hint: '••••••••',
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          size: 16, color: theme.colorScheme.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.arrow_forward_rounded, size: 16),
          label: const Text('Sign in'),
        ),
      ],
    );
  }
}
