import 'package:flutter/material.dart';

import 'cached_image.dart';
import 'tv_tile.dart';

/// Infuse-style "libraries" grid: one artwork card per entry, server-provided
/// backdrop/poster with a gradient + name overlay. Shared by the Jellyfin and
/// Plex browsers at the server level.
class LibraryCardGrid extends StatelessWidget {
  const LibraryCardGrid({
    super.key,
    required this.itemCount,
    required this.artworkFor,
    required this.titleFor,
    required this.onTapFor,
    this.iconFor,
  });

  final int itemCount;

  /// Artwork URL for entry [index] (backdrop preferred, poster fallback), or
  /// null to render the fallback icon tile.
  final String? Function(int index) artworkFor;
  final String Function(int index) titleFor;
  final VoidCallback Function(int index) onTapFor;
  final IconData Function(int index)? iconFor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = (width / 240).floor().clamp(2, 6);
        return GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 16 / 9,
          ),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            final art = artworkFor(index);
            final icon = iconFor?.call(index) ?? Icons.folder;
            return TvFocusWrap(
              onTap: onTapFor(index),
              margin: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  onTap: onTapFor(index),
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (art != null)
                        CachedImage(art, fit: BoxFit.cover)
                      else
                        ColoredBox(
                          color: Theme.of(context)
                              .colorScheme
                              .primaryContainer,
                          child: Icon(icon,
                              color: Theme.of(context).colorScheme.primary),
                        ),
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.78),
                              ],
                              stops: const [0.55, 1.0],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 10,
                        right: 10,
                        bottom: 8,
                        child: Text(
                          titleFor(index),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            shadows: [
                              Shadow(blurRadius: 4, color: Colors.black)
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
