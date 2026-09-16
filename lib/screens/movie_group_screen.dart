import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/cached_image.dart';
import '../models/video_item.dart';
import '../services/tmdb_client.dart';
import '../services/library_folders.dart';
import '../services/series_grouping.dart';
import '../utils/file_info_extractor.dart';
import 'tmd_details_screen.dart';

/// Movie-group detail screen — mirrors the [SeriesSeasonsScreen] layout:
/// backdrop hero app bar, header card (poster + overview + rating + genres),
/// cast row, trailers, then the grouped folders as poster cards below.
class MovieGroupScreen extends StatefulWidget {
  const MovieGroupScreen({super.key, required this.group});

  final SeriesGroup group;

  @override
  State<MovieGroupScreen> createState() => _MovieGroupScreenState();
}

class _MovieGroupScreenState extends State<MovieGroupScreen> {
  TmdMeta? _meta;
  TmdDetails? _details;
  final _scrollController = ScrollController();
  bool _collapsed = false;

  String get _groupKey => widget.group.metadataKey;

  /// Meta shown in the header: the group key first, then any member folder's
  /// cached meta.  A manual group of random cards shows TMDB info from
  /// whichever member has it; null when no member has any.
  TmdMeta? _metaForDisplay() {
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
    if (fresh != _meta) {
      setState(() => _meta = fresh);
    }
  }

  Future<void> _loadDetails() async {
    // Details come from whichever member key has meta (group key first,
    // then any member).  detailsFor returns null for keys with no meta.
    String detailsKey = _groupKey;
    if (_meta == null) {
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
              // with no metadata show just the cards below.
              child: _meta == null
                  ? const SizedBox.shrink()
                  : _Header(
                      meta: _meta,
                      details: _details,
                      title: displayTitle,
                      groupKey: _groupKey,
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
                      final posterUrl =
                          hasMeta ? meta.movie.posterUrl(width: 300) : null;
                      final title = hasMeta
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
                        onTap: () {
                          // Single-file entries open VIDEO mode (like the
                          // home screen's single-file cards) — folder mode
                          // lists a directory, which a file entry doesn't
                          // have ("no videos here" + dead Play button).
                          if (folder.isFile) {
                            final path = folder.videoPath ?? folder.path;
                            final uri = folder.videoUri;
                            final info = extractFileInfo(folder.name);
                            final video = VideoItem(
                              id: 'home_${folder.id}',
                              title: folder.name,
                              path: uri == null ? path : null,
                              uri: uri ?? path,
                              resumeKey: uri ?? path,
                              duration: Duration.zero,
                              sizeBytes: folder.videoSizeBytes,
                              videoCodec: info.videoCodec,
                              audioCodec: info.audioCodec,
                              audioChannels: info.audioChannels,
                              audioLanguage: info.audioLanguage,
                              resolution: info.resolution,
                              fps: info.fps,
                              hdrHint: info.hdrHint,
                            );
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => TmdDetailsScreen(
                                  video: video,
                                  parentMetadataKey: folder.metadataKey,
                                ),
                              ),
                            );
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
/// genres. Mirrors the `_SeriesHeader` layout in series_seasons_screen.dart.
class _Header extends StatefulWidget {
  const _Header({
    required this.meta,
    required this.details,
    required this.title,
    required this.groupKey,
  });

  final TmdMeta? meta;
  final TmdDetails? details;
  final String title;
  final String groupKey;

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
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (rating > 0) ...[
                        const Icon(Icons.star, size: 14, color: Colors.amber),
                        const SizedBox(width: 2),
                        Text(rating.toStringAsFixed(1),
                            style: const TextStyle(fontSize: 12)),
                      ],
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
    required this.onTap,
  });

  final LibraryFolder folder;
  final String? posterUrl;
  final String title;
  final TmdKind? kind;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
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
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: kind == TmdKind.tv
                              ? const Color(0xFF9C27B0)
                              : const Color(0xFF1565C0),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          kind == TmdKind.tv ? 'TV' : 'Movie',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
