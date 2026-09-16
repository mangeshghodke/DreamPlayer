import 'dart:async';

import 'package:flutter/material.dart';
import 'cached_image.dart';
import 'package:flutter/services.dart';

import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/tmdb_client.dart';
import '../utils/tv_helper.dart';

/// Library card for a user-added folder. Shows the folder's TMDB match (poster
/// art, real title, year, TV/Movie chip) when one resolves, otherwise the
/// server-provided [JellyfinItemInfo] for Jellyfin folders, otherwise a
/// gradient + folder icon placeholder.
class FolderCard extends StatefulWidget {
  const FolderCard({
    super.key,
    required this.folder,
    required this.tmdbMeta,
    this.jellyfinInfo,
    required this.onTap,
    this.onLongPress,

    /// When this card represents a [SeriesGroup] (Flux-style collapse of
    /// multiple folders into one), pass the number of folders that were
    /// collapsed. A small badge ("2", "3", ...) appears on the card so the
    /// user knows the group contains more than one folder.
    this.groupCount,
    this.selected = false,

    /// User-entered manual group name — wins over TMDB/folder titles when
    /// set (this card represents a manual group the user created).
    this.displayNameOverride,
  });

  final LibraryFolder folder;
  final TmdMeta? tmdbMeta;

  /// Server-side metadata for a Jellyfin library folder (poster/title/year),
  /// used when no TMDB match is available.
  final JellyfinItemInfo? jellyfinInfo;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

    /// Number of folders collapsed into this card (Flux-style series group).
  final int? groupCount;

  /// User-entered manual group name — wins over TMDB/folder titles.
  final String? displayNameOverride;

  /// Whether this card is currently selected in multi-select mode.
  final bool selected;

  @override
  State<FolderCard> createState() => _FolderCardState();
}

class _FolderCardState extends State<FolderCard> {
  /// Owned focus node handed to the InkWell. Putting focus directly on the
  /// InkWell (rather than a wrapping `Focus`) means D-pad traversal reaches the
  /// card AND `select`/enter activates it through the InkWell's own
  /// ActivateIntent handler. The highlight follows the node via
  /// [ListenableBuilder].
  final FocusNode _focusNode = FocusNode();

  /// TV long-press: hold select/enter for 500 ms to fire [onLongPress].
  Timer? _holdTimer;
  bool _longPressFired = false;

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = _handleKeyEvent;
  }

  @override
  void didUpdateWidget(FolderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!isTvMode(context)) return KeyEventResult.ignored;

    if (event is KeyDownEvent && _isSelectKey(event)) {
      _longPressFired = false;
      _holdTimer?.cancel();
      _holdTimer = Timer(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        _longPressFired = true;
        widget.onLongPress?.call();
      });
      return KeyEventResult.handled;
    }
    // Auto-repeat while holding: swallow, or ActivateIntent fires onTap
    // mid-hold (folder opens *and* the remove dialog appears).
    if (event is KeyRepeatEvent && _isSelectKey(event)) {
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent && _isSelectKey(event)) {
      _holdTimer?.cancel();
      if (!_longPressFired) {
        widget.onTap();
      }
      _longPressFired = false;
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static String _networkLabel(LibraryFolder folder) {
    switch (folder.source) {
      case LibraryFolderSource.smb:
        return folder.networkLabel?.isNotEmpty == true ? 'SMB · ${folder.networkLabel}' : 'SMB';
      case LibraryFolderSource.webdav:
        return folder.networkLabel?.isNotEmpty == true ? 'WebDAV · ${folder.networkLabel}' : 'WebDAV';
      case LibraryFolderSource.ftp:
        return folder.networkLabel?.isNotEmpty == true ? 'FTP · ${folder.networkLabel}' : 'FTP';
      case LibraryFolderSource.upnp:
        return 'DLNA';
      case LibraryFolderSource.jellyfin:
        return 'Jellyfin';
      case LibraryFolderSource.files:
        return '';
    }
  }

  static Color _networkColor(LibraryFolder folder) {
    switch (folder.source) {
      case LibraryFolderSource.smb:
        return const Color(0xFF1976D2);
      case LibraryFolderSource.webdav:
        return const Color(0xFFEF6C00);
      case LibraryFolderSource.ftp:
        return const Color(0xFF6A1B9A);
      case LibraryFolderSource.upnp:
        return const Color(0xFF455A64);
      case LibraryFolderSource.jellyfin:
        return const Color(0xFF00B8A9);
      case LibraryFolderSource.files:
        return Colors.transparent;
    }
  }

  static bool _isSelectKey(KeyEvent e) =>
      e.physicalKey == PhysicalKeyboardKey.enter ||
      e.physicalKey == PhysicalKeyboardKey.select ||
      e.logicalKey == LogicalKeyboardKey.enter ||
      e.logicalKey == LogicalKeyboardKey.select;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final folder = widget.folder;
    final onTap = widget.onTap;
    final onLongPress = widget.onLongPress;
    final movie = widget.tmdbMeta?.movie;
    final hasMeta = movie != null && movie.title.isNotEmpty;
    final info = widget.jellyfinInfo;
    final hasJellyfin = info != null && info.name.isNotEmpty;
    final networkTag = folder.isNetwork ? _networkLabel(folder) : null;
    final subtitle = folder.isFile
        ? _formatFileSize(folder.videoSizeBytes)
        : hasMeta
        ? [
            if (movie.year != null) '${movie.year}',
            movie.kind == TmdKind.tv ? 'TV Series' : 'Movie',
            if (networkTag != null && networkTag.isNotEmpty) networkTag,
          ].join(' · ')
        : hasJellyfin
            ? [
                if (info.kindLabel.isNotEmpty) info.kindLabel,
                if (info.year != null) '${info.year}',
                'Jellyfin',
              ].where((s) => s.isNotEmpty).join(' · ')
            : [
                if (folder.name.isNotEmpty) folder.name,
                if (networkTag != null && networkTag.isNotEmpty) networkTag,
              ].join(' · ');

    // Poster: season poster when a single folder with folderSeason is set,
    // else series poster, else Jellyfin art, else gradient placeholder.
    // Grouped cards (groupCount > 1) always show the series poster since
    // they represent multiple seasons.
    final folderSeason = (widget.groupCount == null || widget.groupCount! <= 1)
        ? widget.tmdbMeta?.folderSeason
        : null;
    final seasonPoster = folderSeason != null
        ? widget.tmdbMeta?.seasons[folderSeason]?.posterUrl()
        : null;
    final posterUrl = hasMeta
        ? (seasonPoster ?? movie.posterUrl())
        : (hasJellyfin ? info.imageUrl : null);

    // Title mirrors the poster rule: a single season folder shows that
    // season's exact name ("Strike the Blood II"), while a grouped card (or a
    // folder that resolves to the whole show) shows the base series title
    // ("Strike the Blood").  A manual group name (displayNameOverride) wins
    // over everything so the user-entered group name shows on the card.
    final seasonName = folderSeason != null
        ? widget.tmdbMeta?.seasons[folderSeason]?.name
        : null;
    final title = (widget.displayNameOverride?.isNotEmpty ?? false)
        ? widget.displayNameOverride!
        : (seasonName?.isNotEmpty ?? false)
            ? seasonName!
            : (hasMeta ? movie.title : (hasJellyfin ? info.name : folder.name));

    // TV/Movie badge: TMDB kind, else the Jellyfin type, else none.
    final kindBadge = hasMeta
        ? (movie.kind == TmdKind.tv ? 'TV' : 'Movie')
        : (hasJellyfin && info.kindLabel.isNotEmpty
            ? (info.isTv ? 'TV' : 'Movie')
            : null);
    final kindColor = (hasMeta && movie.kind == TmdKind.tv) ||
            (hasJellyfin && info.isTv)
        ? const Color(0xFF9C27B0)
        : const Color(0xFF1565C0);

    final tv = isTvMode(context);

    return ListenableBuilder(
      listenable: _focusNode,
      builder: (context, _) {
        final focused = tv && _focusNode.hasFocus;
        return AnimatedScale(
          scale: focused ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: focused
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.4),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ],
                  )
                : null,
            child: Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                focusNode: _focusNode,
                onTap: onTap,
                onLongPress: onLongPress,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  colorScheme.primaryContainer,
                                  colorScheme.tertiaryContainer,
                                ],
                              ),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.video_library_outlined,
                                size: 40,
                                color: Colors.white54,
                              ),
                            ),
                          ),
                          if (posterUrl != null)
                            CachedImage(
                              posterUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                              loadingBuilder: (context, child, progress) =>
                                  progress == null
                                      ? child
                                      : const SizedBox.shrink(),
                            ),
                          if (kindBadge != null)
                            Positioned(
                              top: 8,
                              right: 8,
                              child: _FolderBadge(
                                label: kindBadge,
                                background: kindColor,
                              ),
                            ),
                          if (folder.isNetwork)
                            Positioned(
                              top: 8,
                              left: 8,
                              child: _FolderBadge(
                                label: _networkLabel(folder),
                                background: _networkColor(folder),
                              ),
                            ),
                           if (folder.isFile &&
                              folder.videoSizeBytes != null &&
                              folder.videoSizeBytes! > 0)
                            Positioned(
                              bottom: 8,
                              left: 8,
                              child: _FolderBadge(
                                label: _formatFileSize(folder.videoSizeBytes),
                                background: const Color(0xFF455A64),
                              ),
                            ),
                          if (widget.groupCount != null && widget.groupCount! > 1)
                            Positioned(
                              bottom: 8,
                              right: 8,
                              child: _FolderBadge(
                                label: '×${widget.groupCount}',
                                background: const Color(0xFF2E7D32),
                              ),
                            ),
                          if (widget.selected)
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
                                  border: Border.all(
                                    color: Theme.of(context).colorScheme.primary,
                                    width: 3,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Center(
                                  child: Icon(Icons.check_circle, size: 48, color: Colors.white),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

String _formatFileSize(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class _FolderBadge extends StatelessWidget {
  const _FolderBadge({required this.label, required this.background});

  final String label;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
