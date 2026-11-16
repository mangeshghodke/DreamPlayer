import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cached_image.dart';
import 'tv_tile.dart';

/// Height reserved for the label block under a grid cell's artwork.
///
/// One line for the name and one for the secondary line - the name is
/// deliberately NOT wrapped onto a second line: a two-line name made the
/// tile look broken (the label block grew past the artwork) and the first
/// line is the one that identifies the file anyway.
const double kBrowserEntryLabelHeight = 44;

/// A grid cell for one file or folder in the network browsers' Grid view.
///
/// Windows 11 "medium icons" shape: a 16:9 artwork box on top, the name and a
/// secondary line below. A folder falls back to a folder glyph and a file to a
/// movie/play glyph, so a cell is never blank - a missing poster must not read
/// as "the thumbnail failed to load".
class BrowserEntryCard extends StatelessWidget {
  const BrowserEntryCard({
    super.key,
    required this.title,
    this.subtitle,
    this.artworkUrl,
    this.fallbackIcon = Icons.play_circle_outline,
    this.fallbackColor,
    this.watched = false,
    this.onToggleWatched,
    this.onTap,
    this.onLongPress,
  });

  final String title;
  final String? subtitle;

  /// Artwork for the cell. 16:9 stills and backdrops fit the box exactly;
  /// a 2:3 poster is cover-cropped (top-aligned, so a face is kept).
  final String? artworkUrl;

  final IconData fallbackIcon;
  final Color? fallbackColor;

  /// Whether the entry is marked as watched (drives the toggle glyph).
  final bool watched;

  /// When set, a round toggle is drawn over the artwork's bottom-right corner.
  final VoidCallback? onToggleWatched;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return TvFocusWrap(
      margin: EdgeInsets.zero,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: _artwork(context),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty)
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _artwork(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          fallbackIcon,
          size: 34,
          color: fallbackColor ?? scheme.onSurfaceVariant,
        ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        if (artworkUrl != null && artworkUrl!.isNotEmpty)
          CachedImage(
            artworkUrl!,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            errorBuilder: (_, _, _) => fallback,
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : fallback,
          )
        else
          fallback,
        if (onToggleWatched != null)
          Positioned(
            right: 4,
            bottom: 4,
            child: _WatchToggle(
              watched: watched,
              onPressed: onToggleWatched!,
            ),
          ),
      ],
    );
  }
}

/// The round watched/unwatched toggle drawn over a grid cell's artwork.
class _WatchToggle extends StatelessWidget {
  const _WatchToggle({required this.watched, required this.onPressed});

  final bool watched;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(
            watched ? Icons.check_circle : Icons.check_circle_outline,
            size: 18,
            color: watched ? Colors.green.shade400 : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// The Grid view of a network browser.
///
/// Lays the cells out on a responsive grid: the column count follows the
/// available width and every cell is exactly one 16:9 artwork box plus a
/// fixed label block, so a poster, a still and a folder tile all line up.
class BrowserEntryGrid extends StatelessWidget {
  const BrowserEntryGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 16),
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final EdgeInsets padding;

  /// Target width of one cell. Wider screens get more columns rather than
  /// bigger cells - a cell that grows with the screen stops reading as a
  /// grid and starts reading as a poster card.
  static const double targetCellWidth = 150;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = math.max(
          2,
          math.min(6, (width / targetCellWidth).floor()),
        );
        const spacing = 8.0;
        final cellWidth =
            (width - padding.horizontal - spacing * (columns - 1)) / columns;
        final cellHeight =
            cellWidth * 9 / 16 + kBrowserEntryLabelHeight;

        return GridView.builder(
          padding: padding,
          physics: const AlwaysScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: cellHeight,
          ),
          itemCount: itemCount,
          itemBuilder: (context, index) => itemBuilder(context, index),
        );
      },
    );
  }
}
