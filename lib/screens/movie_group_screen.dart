import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/cached_image.dart';
import '../services/manual_groups.dart';
import '../services/network_video_resolver.dart';
import '../services/tmdb_client.dart';
import '../services/library_folders.dart';
import '../services/series_grouping.dart';
import '../widgets/group_poster_dialog.dart';
import 'tmd_details_screen.dart';

/// Movie-group detail screen — mirrors the [SeriesSeasonsScreen] layout:
/// backdrop hero app bar, header card (poster + overview + rating + genres),
/// cast row, trailers, then the grouped folders as poster cards below.
class MovieGroupScreen extends StatefulWidget {
  const MovieGroupScreen({
    super.key,
    required this.group,

    /// User-picked TMDB metadata for the group's poster (chosen at group
    /// creation) — wins over any member's cached meta in the header/backdrop.
    this.posterMeta,

    /// The manual group's store id — drives the Fix match / Remove-info
    /// buttons on the header (posterMeta persisted via
    /// [ManualGroupsStore.setPosterMeta]).
    this.manualGroupId,
  });

  final SeriesGroup group;
  final TmdMeta? posterMeta;
  final String? manualGroupId;

  @override
  State<MovieGroupScreen> createState() => _MovieGroupScreenState();
}

class _MovieGroupScreenState extends State<MovieGroupScreen> {
  TmdMeta? _meta;
  TmdDetails? _details;
  final _scrollController = ScrollController();
  bool _collapsed = false;

  String get _groupKey => widget.group.metadataKey;

  /// Meta shown in the header: the user-picked manual poster first, then the
  /// group key, then any member folder's cached meta.  A manual group of
  /// random cards shows TMDB info from whichever member has it; null when no
  /// member has any.
  TmdMeta? _metaForDisplay() {
    if (widget.posterMeta != null) return widget.posterMeta;
    final primary = TmdService.instance.metaFor(_groupKey);
    if (primary != null) return primary;
    for (final f in widget.group.folders) {
      final m = TmdService.instance.metaFor(f.metadataKey);
      if (m != null) return m;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _meta = _metaForDisplay();
    TmdService.instance.addListener(_onMetaChanged);
    _scrollController.addListener(_onScroll);
    _loadDetails();
  }

  @override
  void dispose() {
    TmdService.instance.removeListener(_onMetaChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final threshold = 220.0 - kToolbarHeight - 24;
    final collapsed = _scrollController.hasClients &&
        _scrollController.offset > threshold;
    if (collapsed != _collapsed) {
      setState(() => _collapsed = collapsed);
    }
  }

  void _onMetaChanged() {
    if (!mounted) return;
    final fresh = _metaForDisplay();
    final providerChanged = fresh?.movie.providerKey != _meta?.movie.providerKey;
    if (fresh != _meta) {
      setState(() {
        _meta = fresh;
        if (providerChanged) _details = fresh?.details;
      });
    }
  }

  Future<void> _loadDetails() async {
    final displayMeta = _metaForDisplay();
    if (displayMeta?.details != null) {
      if (mounted) setState(() => _details = displayMeta!.details);
      return;
    }
    // Details come from whichever member key has meta (group key first,
    // then any member).  detailsFor returns null for keys with no meta.
    String detailsKey = _groupKey;
    if (displayMeta == null) {
      for (final f in widget.group.folders) {
        if (TmdService.instance.metaFor(f.metadataKey) != null) {
          detailsKey = f.metadataKey;
          break;
        }
      }
    }
    final d = await TmdService.instance.detailsFor(detailsKey);
    if (!mounted) return;
    setState(() => _details = d);
  }

  /// Fix match — TMDB search dialog (query prefilled with the group name);
  /// the picked [TmdMeta] becomes the group's poster (persisted via
  /// [ManualGroupsStore.setPosterMeta]) and the header/backdrop refresh.
  Future<void> _fixMatch() async {
    final picked = await showDialog<TmdMeta>(
      context: context,
      builder: (_) => GroupPosterDialog(initialQuery: _displayName),
    );
    if (picked == null || !mounted) return;
    final details = picked.details ??
        await TmdService.instance.detailsForMovie(picked.movie);
    final enriched = details == null ? picked : picked.withDetails(details);
    final id = widget.manualGroupId;
    if (id != null) {
      await ManualGroupsStore.instance.setPosterMeta(id, enriched);
    }
    if (!mounted) return;
    setState(() {
      _meta = enriched;
      _details = enriched.details;
    });
  }

  /// Remove info — clears the user-picked poster so the group falls back to
  /// any member's cached meta (or just the cards when no member has any).
  Future<void> _removeInfo() async {
    final id = widget.manualGroupId;
    if (id != null) {
      await ManualGroupsStore.instance.setPosterMeta(id, null);
    }
    setState(() {
      _meta = null;
      _details = null;
    });
  }

  /// Opens a single-file entry in VIDEO mode. File entries carry synthetic
  /// paths for network sources — [NetworkVideoResolver] rebuilds the real
  /// playable URL per source (WebDAV server lookup + auth, Jellyfin
  /// streamUrl, SMB/local direct, UPnP parent re-browse).
  Future<void> _openFileEntry(LibraryFolder folder) async {
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
          parentMetadataKey: folder.metadataKey,
        ),
      ),
    );
  }

  String get _displayName {
    // Manual group name (user-entered) wins; else strip fansub tags from
    // the TMDB title / folder display name.
    var name = widget.group.displayName;
    name = name.replaceAll(RegExp(r'\[.*?\]'), ' ');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    return name.isNotEmpty ? name : widget.group.folders.first.name;
  }

  static int _columnsForWidth(double width) {
    if (width >= 1000) return 6;
    if (width >= 760) return 4;
    if (width >= 480) return 3;
    return 2;
  }

  void _launchTrailer(String url) {
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final backdrop = _meta?.movie.backdropUrl();
    final displayTitle = _displayName;
    final folders = widget.group.folders;
    return Scaffold(
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 220,
            title: AnimatedOpacity(
              opacity: _collapsed ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Text(displayTitle),
            ),
            flexibleSpace: _CollapsingBackdrop(
              backdrop: backdrop,
              collapsed: _collapsed,
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            sliver: SliverToBoxAdapter(
              // Header card only when a member has TMDB info — random groups
              // with no metadata show a Get Info escape hatch (small card).
              child: _meta == null
                  ? Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline,
                                size: 20, color: Colors.grey),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text('No metadata loaded',
                                  style: TextStyle(fontSize: 14)),
                            ),
                            TextButton(
                              onPressed: _fixMatch,
                              child: const Text('Get Info'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _Header(
                      meta: _meta,
                      details: _details,
                      title: displayTitle,
                      groupKey: _groupKey,
                      onFixMatch: _fixMatch,
                      onRemoveInfo: _removeInfo,
                    ),
            ),
          ),
          if (_details != null && _details!.cast.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              sliver: SliverToBoxAdapter(
                child: _CastRow(cast: _details!.cast),
              ),
            ),
          if (_details != null && _details!.trailers.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              sliver: SliverToBoxAdapter(
                child: _TrailersRow(
                  trailers: _details!.trailers,
                  onLaunch: _launchTrailer,
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            sliver: SliverToBoxAdapter(
              child: Text(
                '${folders.length} movies',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.crossAxisExtent;
                final columns = _columnsForWidth(width);
                const spacing = 14.0;
                final itemWidth = (width - spacing * (columns - 1)) / columns;
                const textBlockHeight = 84.0;
                final itemHeight = itemWidth * 3 / 2 + textBlockHeight;
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                    mainAxisExtent: itemHeight,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      if (index >= folders.length) {
                        return const SizedBox.shrink();
                      }
                      final folder = folders[index];
                      final meta =
                          TmdService.instance.metaFor(folder.metadataKey);
                      final hasMeta =
                          meta != null && meta.movie.title.isNotEmpty;
                      // Season poster/name when the folder's meta carries a
                      // folderSeason (e.g. Strike the Blood II → Season 2) —
                      // each card inside the group represents ONE folder, so
                      // the season art shows instead of the series' Season-1
                      // poster. Movie parts (folderSeason null) keep the
                      // movie poster.
                      final fs = (meta?.folderSeason != null &&
                              (meta!.folderSeason ?? 0) > 0)
                          ? meta.folderSeason
                          : null;
                      final seasonPoster =
                          (fs != null && meta != null)
                              ? meta.seasons[fs]?.posterUrl()
                              : null;
                      final seasonName = (fs != null && meta != null)
                          ? meta.seasons[fs]?.name
                          : null;
                      final posterUrl = seasonPoster ??
                          (hasMeta ? meta.movie.posterUrl(width: 300) : null);
                      final title = (seasonName?.isNotEmpty ?? false)
                          ? seasonName!
                          : hasMeta
                              ? meta.movie.title
                              : folder.name
                                  .replaceAll(RegExp(r'\[.*?\]'), ' ')
                                  .replaceAll(RegExp(r'\s+'), ' ')
                                  .trim();
                      return _MovieGroupCard(
                        folder: folder,
                        posterUrl: posterUrl,
                        title: title,
                        kind: meta?.movie.kind,
                        year: meta?.movie.year,
                        onTap: () {
                          // Single-file entries open VIDEO mode (like the
                          // home screen's single-file cards) — folder mode
                          // lists a directory, which a file entry doesn't
                          // have ("no videos here" + dead Play button).
                          if (folder.isFile) {
                            _openFileEntry(folder);
                            return;
                          }
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => TmdDetailsScreen(folder: folder),
                            ),
                          );
                        },
                      );
                    },
                    childCount: folders.length,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Header card — poster + title + year + overview (expandable) + rating +
/// genres + Fix match/Remove buttons. Mirrors the `_SeriesHeader` layout in
/// series_seasons_screen.dart.
class _Header extends StatefulWidget {
  const _Header({
    required this.meta,
    required this.details,
    required this.title,
    required this.groupKey,
    required this.onFixMatch,
    this.onRemoveInfo,
  });

  final TmdMeta? meta;
  final TmdDetails? details;
  final String title;
  final String groupKey;
  final VoidCallback onFixMatch;
  final VoidCallback? onRemoveInfo;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final movie = widget.meta?.movie;
    final hasMeta = movie != null && movie.title.isNotEmpty;
    final details = widget.details;

    if (!hasMeta) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 20, color: Colors.grey),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('No metadata loaded',
                    style: TextStyle(fontSize: 14)),
              ),
            ],
          ),
        ),
      );
    }

    final poster = movie.posterUrl();
    final overview = details?.overview ?? '';
    final rating = movie.voteAverage;
    final genres = details?.genres ?? const <String>[];

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (poster != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedImage(
                  poster,
                  width: 72,
                  height: 108,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  if (movie.year != null)
                    Text(
                      '${movie.year}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  if (overview.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Overview',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      overview,
                      maxLines: _expanded ? null : 4,
                      overflow: _expanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _expanded = !_expanded),
                      child: Text(
                        _expanded ? 'Less' : 'More',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ],
                  if (movie.provider == MetadataProvider.theTvdb) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _openTheTvdb,
                        icon: const Icon(Icons.open_in_new, size: 14),
                        label: const Text('Metadata by TheTVDB'),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                    Text(
                      'This product uses the TheTVDB API but is not endorsed by TheTVDB.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 6),
                  Row(

                    children: [
                      if (rating > 0) ...[
                        const Icon(Icons.star, size: 14, color: Colors.amber),
                        const SizedBox(width: 2),
                        Text(rating.toStringAsFixed(1),
                            style: const TextStyle(fontSize: 12)),
                        const SizedBox(width: 12),
                      ],
                      Flexible(
                        child: TextButton(
                          onPressed: widget.onFixMatch,
                          child: Text(widget.onRemoveInfo != null
                              ? 'Fix match'
                              : 'Get Info'),
                        ),
                      ),
                      if (widget.onRemoveInfo != null)
                        Flexible(
                          child: TextButton(
                            onPressed: widget.onRemoveInfo,
                            child: const Text('Remove'),
                          ),
                        ),
                    ],
                  ),
                  if (genres.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final genre in genres)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              genre,
                              style:
                                  Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openTheTvdb() async {
    await launchUrl(
      Uri.parse('https://thetvdb.com/'),
      mode: LaunchMode.externalApplication,
    );
  }
}

/// Horizontal scrollable cast row — mirrors `_CastRow` in
/// series_seasons_screen.dart.
class _CastRow extends StatelessWidget {
  const _CastRow({required this.cast});
  final List<TmdCastMember> cast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cast',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 130,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cast.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final member = cast[index];
              return SizedBox(
                width: 80,
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(40),
                      child: member.profileUrl() != null
                          ? CachedImage(
                              member.profileUrl()!,
                              width: 72,
                              height: 72,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  _avatarFallback(theme.colorScheme, member.name),
                            )
                          : _avatarFallback(theme.colorScheme, member.name),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      member.name,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    if (member.character != null &&
                        member.character!.isNotEmpty)
                      Text(
                        member.character!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _avatarFallback(ColorScheme colorScheme, String name) {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}

/// Horizontal trailers row — mirrors the `_TrailersCard` layout.
class _TrailersRow extends StatelessWidget {
  const _TrailersRow({required this.trailers, required this.onLaunch});

  final List<TmdTrailer> trailers;
  final void Function(String url) onLaunch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Trailers',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final t in trailers.take(5))
              OutlinedButton.icon(
                onPressed: () {
                  final url = t.youtubeUrl;
                  if (url != null) onLaunch(url);
                },
                icon: const Icon(Icons.play_circle_outline, size: 18),
                label: Text(
                  t.name.isEmpty ? 'Trailer' : t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A flexible space that shows a clean backdrop when expanded and fades it
/// out as the app bar collapses — mirrors `_CollapsingBackdrop` in
/// series_seasons_screen.dart.
class _CollapsingBackdrop extends StatelessWidget {
  const _CollapsingBackdrop({
    required this.backdrop,
    required this.collapsed,
  });

  final String? backdrop;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (backdrop != null)
          AnimatedOpacity(
            opacity: collapsed ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: CachedImage(
              backdrop!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  Container(color: theme.colorScheme.surfaceContainerHighest),
            ),
          )
        else
          Container(color: theme.colorScheme.surfaceContainerHighest),
      ],
    );
  }
}

class _MovieGroupCard extends StatelessWidget {
  const _MovieGroupCard({
    required this.folder,
    required this.posterUrl,
    required this.title,
    this.kind,
    this.year,
    required this.onTap,
  });

  final LibraryFolder folder;
  final String? posterUrl;
  final String title;
  final TmdKind? kind;
  final int? year;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final kindBadge = kind != null ? (kind == TmdKind.tv ? 'TV' : 'Movie') : null;
    final kindColor =
        kind == TmdKind.tv ? const Color(0xFF9C27B0) : const Color(0xFF1565C0);
    final subtitle = [
      year != null ? '$year' : null,
      kindBadge,
    ].whereType<String>().join(' · ');
    return GestureDetector(
      onTap: onTap,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
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
                        size: 48,
                        color: Colors.white54,
                      ),
                    ),
                  ),
                  if (posterUrl != null)
                    CachedImage(
                      posterUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      loadingBuilder: (context, child, progress) =>
                          progress == null
                              ? child
                              : const SizedBox.shrink(),
                    ),
                  if (kind != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: kindColor,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          kindBadge ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
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
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
