import 'package:flutter/material.dart';

import '../services/plex_client.dart';
import '../widgets/episode_row.dart';
import '../widgets/library_card_grid.dart';
import '../widgets/server_form_kit.dart';
import '../widgets/tv_tile.dart';
import 'tmd_details_screen.dart';

class PlexScreen extends StatefulWidget {
  const PlexScreen({super.key});

  @override
  State<PlexScreen> createState() => _PlexScreenState();
}

class _Crumb {
  const _Crumb({this.id, required this.name});
  final String? id;
  final String name;
}

class _PlexScreenState extends State<PlexScreen> {
  final PlexClient _client = PlexClient();

  List<PlexServer> _servers = const [];
  PlexServer? _browsing;
  List<_Crumb> _crumbs = const [];
  List<PlexItem> _items = const [];
  bool _loading = true;
  String? _error;

  bool get _atBrowseRoot => _browsing == null;

  @override
  void initState() {
    super.initState();
    _loadServers();
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

  // ---------------------------------------------------------------------------
  // Browsing
  // ---------------------------------------------------------------------------

  Future<void> _openServer(PlexServer server) async {
    if (!server.isAuthenticated) {
      final creds = await _showLoginDialog(server);
      if (creds == null) return;
      PlexServer? signedIn;
      try {
        signedIn = await _client.authenticate(
          server,
          creds.username,
          creds.password,
        );
        await _saveServer(signedIn);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(PlexClient.friendlyError(e))),
        );
        return;
      }
      if (!mounted) return;
      server = signedIn;
    }
    setState(() {
      _browsing = server;
      _crumbs = const [];
      _loading = true;
      _error = null;
    });
    await _loadLevel();
  }

  Future<void> _saveServer(PlexServer server) async {
    final servers = await _client.loadServers();
    final index = servers.indexWhere((s) => s.url == server.url);
    final updated = [...servers];
    if (index >= 0) {
      updated[index] = server;
    } else {
      updated.add(server);
    }
    await _client.saveServers(updated);
    if (!mounted) return;
    setState(() => _servers = updated);
  }

  Future<void> _loadLevel() async {
    final server = _browsing;
    if (server == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final parentId = _crumbs.isEmpty ? null : _crumbs.last.id;
    try {
      final res = await _client.withAltFailover(
        server,
        (s) => parentId == null ? _client.getLibraries(s) : _client.getItems(s, parentId),
      );
      if (!mounted) return;
      final items = [...res.value];
      // Sections/folders first, then playables, each sorted by name.
      final folders = items.where((i) => i.isFolder).toList()
        ..sort(_byName);
      final playables = items.where((i) => i.isPlayable).toList()
        ..sort(_byName);
      setState(() {
        _browsing = res.server;
        _items = [...folders, ...playables];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = PlexClient.friendlyError(e);
      });
    }
  }

  int _byName(PlexItem a, PlexItem b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  Future<void> _openItem(PlexItem item) async {
    final server = _browsing;
    if (server == null) return;
    if (item.isPlayable) {
      final meta = await _client.withAltFailover(server, (s) =>
          _client.getMarkers(s, item.id).catchError(
              (e, st) => const <Never>[]));
      if (!mounted) return;
      final withChapters = PlexItem(
        id: item.id,
        name: item.name,
        type: item.type,
        isFolder: item.isFolder,
        sectionKey: item.sectionKey,
        sectionType: item.sectionType,
        parentId: item.parentId,
        index: item.index,
        parentIndex: item.parentIndex,
        seriesTitle: item.seriesTitle,
        seasonTitle: item.seasonTitle,
        durationMs: item.durationMs,
        resolutionLabel: item.resolutionLabel,
        sizeBytes: item.sizeBytes,
        rating: item.rating,
        year: item.year,
        partId: item.partId,
        container: item.container,
        thumbPath: item.thumbPath,
        chapters: meta.value,
      );
      final video = _client.videoItem(meta.server, withChapters);
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(video: video),
      ));
      return;
    }
    setState(() {
      _crumbs = [..._crumbs, _Crumb(id: item.id, name: item.name)];
    });
    await _loadLevel();
  }

  Future<void> _goUp() async {
    if (_crumbs.isEmpty) {
      setState(() {
        _browsing = null;
        _items = const [];
        _loading = true;
      });
      await _loadServers();
      return;
    }
    setState(() {
      _crumbs = _crumbs.sublist(0, _crumbs.length - 1);
    });
    await _loadLevel();
  }

  // ---------------------------------------------------------------------------
  // Server management
  // ---------------------------------------------------------------------------

  void _addServer() {
    showModalBottomSheet<Widget>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _PlexServerFormDialog(),
    ).then((_) => _loadServers());
  }

  void _editServer(PlexServer server) {
    showModalBottomSheet<Widget>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PlexServerFormDialog(existing: server),
    ).then((_) => _loadServers());
  }

  Future<void> _removeServer(PlexServer server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove server'),
        content: Text('Remove ${server.name.isEmpty ? server.url : server.name} from your Plex list?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final servers = await _client.removeServer(server.url);
    if (!mounted) return;
    setState(() {
      _servers = servers;
      if (_browsing?.url == server.url) {
        _browsing = null;
        _crumbs = const [];
        _items = const [];
      }
    });
  }

  Future<({String username, String password})?> _showLoginDialog(
    PlexServer existing,
  ) {
    return showDialog<({String username, String password})>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PlexLoginDialog(
        serverName: existing.name.isEmpty ? existing.url : existing.name,
        url: existing.url,
        username: existing.username,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_atBrowseRoot) return _buildBrowse(context);
    return _buildServersView(context);
  }

  Widget _buildServersView(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plex'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_link),
            tooltip: 'Add server',
            onPressed: _addServer,
          ),
        ],
      ),
      floatingActionButton: _servers.isEmpty
          ? FloatingActionButton.extended(
              onPressed: _addServer,
              icon: const Icon(Icons.add),
              label: const Text('Add server'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _servers.isEmpty
              ? _buildEmpty(theme)
              : ListView(
                  children: [
                    for (final server in _servers)
                      _ServerRow(
                        server: server,
                        onTap: () => _openServer(server),
                        onEdit: () => _editServer(server),
                        onRemove: () => _removeServer(server),
                      ),
                  ],
                ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.perm_media_outlined,
                size: 64, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            const Text('Connect to a Plex Media Server',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              'Browse and play movies and shows on your Plex server over the local network.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 13.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowse(BuildContext context) {
    final server = _browsing!;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _goUp();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(server.name.isEmpty ? server.url : server.name),
        leading: IconButton(
          tooltip: 'Up',
          icon: const Icon(Icons.arrow_back),
          onPressed: _goUp,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_crumbs.isNotEmpty)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 6),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: () {
                            setState(() => _crumbs = const []);
                            _loadLevel();
                          },
                          child: const Text('Libraries'),
                        ),
                        for (final crumb in _crumbs) ...[
                          const Icon(Icons.chevron_right, size: 18),
                          Text(crumb.name),
                        ],
                      ],
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error),
                    ),
                  )
                else
                  Expanded(
                    // Libraries level (no crumbs): Infuse-style artwork cards
                    // using the server's own art/thumb. Inner levels: rows
                    // with poster thumbnails.
                    child: _crumbs.isEmpty
                        ? LibraryCardGrid(
                            itemCount: _items.length,
                            artworkFor: (i) =>
                                _client.artUrl(server, _items[i]) ??
                                _client.thumbUrl(server, _items[i]),
                            titleFor: (i) => _items[i].name,
                            onTapFor: (i) => () => _openItem(_items[i]),
                            iconFor: (_) => Icons.video_library_outlined,
                          )
                        : ListView(
                            children: [
                              for (final item in _items)
                                _ItemRow(
                                  item: item,
                                  thumbUrl: _client.thumbUrl(server, item),
                                  onTap: () => _openItem(item),
                                ),
                            ],
                          ),
                  ),
              ],
            ),
        ),
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.server,
    required this.onTap,
    required this.onEdit,
    required this.onRemove,
  });

  final PlexServer server;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TvFocusWrap(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      onTap: onTap,
      onLongPress: onEdit,
      child: ListTile(
        leading: Icon(Icons.dns_outlined, color: theme.colorScheme.primary),
        title: Text(
          server.name.isEmpty ? server.url : server.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          server.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'edit') onEdit();
            if (value == 'remove') onRemove();
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'edit', child: Text('Edit')),
            const PopupMenuItem(value: 'remove', child: Text('Remove')),
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.onTap,
    this.thumbUrl,
  });

  final PlexItem item;
  final VoidCallback onTap;

  /// Server-provided poster URL (thumb), or null for the plain icon row.
  final String? thumbUrl;

  IconData get _icon {
    if (item.type == 'episode') return Icons.smart_display_outlined;
    if (item.type == 'season' || item.type == 'show') {
      return Icons.folder_outlined;
    }
    if (item.isSection) return Icons.video_library_outlined;
    return Icons.movie_outlined;
  }

  String? get _subtitle {
    if (item.isEpisode) {
      final code = item.episodeCode;
      final series = item.seriesTitle;
      return series == null
          ? code
          : '$series${code == null ? '' : ' · $code'}';
    }
    if (item.type == 'show') return null;
    if (item.durationMs != null) {
      final mins = (item.durationMs! / 60000).round();
      return '$mins min';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tile = ListTile(
        leading: Icon(
            _icon,
            color: item.isPlayable
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant),
        title: Text(
          item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: _subtitle == null
            ? null
            : Text(
                _subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: item.isPlayable
            ? const Icon(Icons.play_circle_outline)
            : const Icon(Icons.chevron_right),
      );
    // With a server poster the row renders as an EpisodeRow thumb; ListTile
    // keeps its own onTap so touch works (TvFocusWrap only covers TV keys).
    if (thumbUrl != null) {
      return TvFocusWrap(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        onTap: onTap,
        child: EpisodeRow(
          thumbBuilder: (size) =>
              EpisodePosterThumb(posterUrl: thumbUrl, size: size),
          title: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: _subtitle == null
              ? null
              : Text(
                  _subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: item.isPlayable
              ? const Icon(Icons.play_circle_outline)
              : const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      );
    }
    return TvFocusWrap(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      onTap: onTap,
      child: tile,
    );
  }
}

class _PlexServerFormDialog extends StatefulWidget {
  const _PlexServerFormDialog({this.existing});

  final PlexServer? existing;

  @override
  State<_PlexServerFormDialog> createState() => _PlexServerFormDialogState();
}

class _PlexServerFormDialogState extends State<_PlexServerFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late bool _selfSigned;
  bool _busy = false;
  bool _resultSuccess = false;
  String? _resultMessage;

  PlexServer? get _existing => widget.existing;

  @override
  void initState() {
    super.initState();
    final existing = _existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _url = TextEditingController(text: existing?.url ?? '');
    _username = TextEditingController(text: existing?.username ?? '');
    _password = TextEditingController();
    _selfSigned = existing?.allowSelfSigned ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() {
        _resultSuccess = false;
        _resultMessage = 'Enter the server address.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _resultMessage = 'Testing…';
      _resultSuccess = false;
    });
    try {
      final info = await PlexClient().testConnection(
        url,
        allowSelfSigned: _selfSigned,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _resultSuccess = true;
        _resultMessage =
            'Connected (${info.displayName}${info.version == null ? '' : ' · ${info.version}'})';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _resultSuccess = false;
        _resultMessage = PlexClient.friendlyError(e);
      });
    }
  }

  Future<void> _save() async {
    final url = PlexClient.normalizeUrl(_url.text.trim());
    if (url.isEmpty) {
      setState(() {
        _resultSuccess = false;
        _resultMessage = 'Enter the server address.';
      });
      return;
    }
    final existing = _existing;
    final keepToken = existing != null &&
        PlexClient.normalizeUrl(existing.url) == url &&
        existing.isAuthenticated;
    final server = PlexServer(
      name: _name.text.trim(),
      url: url,
      username: _username.text.trim(),
      token: keepToken ? existing.token : null,
      machineIdentifier: keepToken ? existing.machineIdentifier : null,
      allowSelfSigned: _selfSigned,
      altUrl: null,
      autoDiscovered: false,
    );
    await PlexClient().addServer(server);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return serverDialog(
      title: ServerDialogTitle(
        icon: _existing == null ? Icons.add_link : Icons.dns_outlined,
        title: _existing == null ? 'Add Plex server' : 'Edit Plex server',
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
                        hint: 'e.g. Living room Plex',
                        icon: Icons.badge_outlined,
                        optional: true,
                      ),
                    ),
                    SizedBox(height: 14),
                    ServerTextField(
                      controller: _url,
                      autofocus: _existing == null,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      decoration: serverFieldDecoration(
                        context,
                        label: 'Server address',
                        hint: 'http://192.168.1.10:32400',
                        icon: Icons.lan_outlined,
                      ),
                    ),
                    SizedBox(height: 14),
                    ServerTextField(
                      controller: _username,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      decoration: serverFieldDecoration(
                        context,
                        label: 'Plex username',
                        hint: 'example@domain.com',
                        icon: Icons.person_outline,
                        optional: true,
                      ),
                    ),
                    SizedBox(height: 14),
                    ServerPasswordField(
                      icon: Icons.lock_outline,
                      controller: _password,
                      label: 'Password',
                      hint: '••••••••',
                    ),
                    SwitchListTile(
                      contentPadding: const EdgeInsets.only(top: 4),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      activeThumbColor: theme.colorScheme.primary,
                      title: const Text('Allow self-signed certificates',
                          style: TextStyle(fontSize: 14)),
                      value: _selfSigned,
                      onChanged: (v) => setState(() => _selfSigned = v),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _busy ? null : _test,
                  icon: const Icon(Icons.wifi_tethering, size: 18),
                  label: const Text('Test'),
                ),
                if (_resultMessage != null)
                  Expanded(
                    child: ServerResultBanner(
                      success: _resultSuccess,
                      message: _resultMessage!,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(MaterialLocalizations.of(context).saveButtonLabel),
        ),
      ],
    );
  }
}

class _PlexLoginDialog extends StatefulWidget {
  const _PlexLoginDialog({
    required this.serverName,
    required this.url,
    required this.username,
  });

  final String serverName;
  final String url;
  final String username;

  @override
  State<_PlexLoginDialog> createState() => _PlexLoginDialogState();
}

class _PlexLoginDialogState extends State<_PlexLoginDialog> {
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
    final username = _username.text.trim();
    if (username.isEmpty) {
      setState(() => _error = 'Enter your username.');
      return;
    }
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // The screen owns the authenticate + save; this dialog only collects
    // credentials so login happens exactly once.
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
                  hint: 'example@domain.com',
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
                            color: theme.colorScheme.error,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Sign in'),
        ),
      ],
    );
  }
}
