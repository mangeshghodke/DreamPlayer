import 'package:flutter/material.dart';

import '../services/layout_store.dart';
import 'cached_image.dart';
import 'tv_tile.dart';

/// Pixel sizes for [EpisodeThumbSize] (issue #38, items 1-3).
///
/// The old rows asked a `ListTile` for a `48x72` leading, but `ListTile`
/// clamps `leading` to **56 px** tall (`maxIconHeightConstraint` in
/// `list_tile.dart`), so users actually saw a 48x56 image and the extra 16 px
/// was silently discarded. `ListTileTheme.minTileHeight` does *not* lift that
/// cap — it is hardcoded, independent of `minTileHeight` — which is why these
/// rows cannot be `ListTile`s and are built from a `Row` instead.
extension EpisodeThumbGeometry on EpisodeThumbSize {
  /// Wide TMDB **episode still** (16:9) used by the network browsers and the
  /// season screen. `small` is the pre-existing 64x40.
  ({double w, double h}) get still => switch (this) {
        EpisodeThumbSize.small => (w: 64, h: 40),
        EpisodeThumbSize.medium => (w: 112, h: 63),
        EpisodeThumbSize.large => (w: 168, h: 95),
      };

  /// Tall **poster** fallback when there is no still for the episode.
  ///
  /// `small` is 48x56, NOT the 48x72 the old `_Poster` asked for: `ListTile`
  /// clamped it, so 56 is the height users actually saw. Using 72 here would
  /// make the default *taller* than before, which is the opposite of leaving
  /// existing installs alone.
  ({double w, double h}) get poster => switch (this) {
        EpisodeThumbSize.small => (w: 48, h: 56),
        EpisodeThumbSize.medium => (w: 72, h: 108),
        EpisodeThumbSize.large => (w: 96, h: 144),
      };

  /// Minimum row height. `small` is pinned to 56 px — exactly what a non-dense
  /// `ListTile` produced — so enabling nothing changes nothing. Larger sizes
  /// derive from the tallest thumbnail plus the vertical padding.
  double get rowMinHeight {
    if (this == EpisodeThumbSize.small) return 56;
    final tallest = poster.h > still.h ? poster.h : still.h;
    return tallest + vPadding * 2;
  }

  /// Vertical padding around the row's content.
  static const double vPadding = 8;
}

/// Key on the pinned thumbnail box, so tests can measure what is actually laid
/// out rather than the (zero-sized, while-loading) image inside it.
const kEpisodeThumbBoxKey = ValueKey('episode-thumb-box');

/// The wide TMDB still thumbnail for an episode row, sized by the user's
/// preference. Falls back to a film icon, matching the old per-screen blocks.
///
/// The box is pinned rather than left to the image: `CachedImage` returns
/// `SizedBox.shrink()` while loading, so without an explicit `SizedBox` the row
/// would collapse to text height and then jump as each still arrives.
class EpisodeStillThumb extends StatelessWidget {
  const EpisodeStillThumb({
    super.key,
    required this.stillUrl,
    this.posterUrl,
    this.size,
    this.fallbackIcon,
  });

  /// The TMDB episode still (16:9). Preferred when present.
  final String? stillUrl;

  /// Poster (2:3) used when there is no still for this episode. The old rows
  /// fell back to a 48x72 `_Poster` here, so dropping it would have made every
  /// still-less episode lose its artwork; routing it through this widget keeps
  /// the poster AND makes it honour the size preference.
  final String? posterUrl;

  final EpisodeThumbSize? size;

  /// Icon drawn when there is no still. Callers that used a custom placeholder
  /// (e.g. a parsed-episode glyph) pass it here so converting to this widget
  /// does not silently change what the row looks like.
  final Widget? fallbackIcon;

  /// Clamps the chosen size so the thumbnail never crowds out the text on a
  /// narrow phone. The feature is aimed at tablets; a 168 px still on a 320 dp
  /// screen would leave ~120 dp for title, subtitle and progress.
  EpisodeThumbSize _effective(BuildContext context) {
    final s = size ?? LayoutStore.instance.thumbSize;
    final width = MediaQuery.sizeOf(context).width;
    // Everything the row spends on anything that is NOT the text column:
    // the thumbnail, the 12px gap, and 12px of padding on each side.
    final overhead = s.still.w + _gap + _hPadding * 2;
    final forText = width - overhead;
    if (forText >= minTextWidth) return s;
    // Only ever demote one step, so "large" on a 390dp phone lands on medium
    // (or small) rather than jumping straight past the user's intent.
    return switch (s) {
      EpisodeThumbSize.large => EpisodeThumbSize.medium,
      EpisodeThumbSize.medium => EpisodeThumbSize.small,
      EpisodeThumbSize.small => EpisodeThumbSize.small,
    };
  }

  /// Narrowest text column we will render before demoting the thumbnail.
  static const double minTextWidth = 200;

  /// Must match the gap and padding in [EpisodeRow.build].
  static const double _gap = 12;
  static const double _hPadding = 12;

  @override
  Widget build(BuildContext context) {
    // Each thumb listens for ITSELF rather than relying on [EpisodeRow] to
    // rebuild it: callers construct the thumb and pass it in, and because these
    // are const-constructible the row's rebuild hands back an identical widget,
    // which Flutter short-circuits - so a row-driven rebuild would never
    // actually resize the thumbnail.
    return ListenableBuilder(
      listenable: LayoutStore.instance,
      builder: (context, _) {
        final s = _effective(context);
        final icon = fallbackIcon ??
            Icon(
              Icons.movie_outlined,
              color: Theme.of(context).colorScheme.secondary,
            );
        final url = stillUrl;
        // No still -> fall back to the poster at the same size preference,
        // rather than a bare icon.
        if (url == null || url.isEmpty) {
          if (posterUrl != null && posterUrl!.isNotEmpty) {
            return EpisodePosterThumb(
              key: kEpisodeThumbBoxKey,
              posterUrl: posterUrl,
              size: s,
            );
          }
          return SizedBox(
            key: kEpisodeThumbBoxKey,
            width: s.still.w,
            height: s.still.h,
            child: Center(child: icon),
          );
        }
        final box = s.still;
        return SizedBox(
          key: kEpisodeThumbBoxKey,
          width: box.w,
          height: box.h,
          child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                child: CachedImage(
                  url,
                  width: box.w,
                  height: box.h,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Center(child: icon),
                ),
              ),
        );
      },
    );
  }
}

/// The tall poster thumbnail for an episode/file row, sized by the user's
/// preference.
class EpisodePosterThumb extends StatelessWidget {
  const EpisodePosterThumb({super.key, required this.posterUrl, this.size});

  final String? posterUrl;
  final EpisodeThumbSize? size;

  @override
  Widget build(BuildContext context) {
    // Self-listening for the same reason as [EpisodeStillThumb].
    return ListenableBuilder(
      listenable: LayoutStore.instance,
      builder: (context, _) {
        final s = size ?? LayoutStore.instance.thumbSize;
        final icon = Icon(
          Icons.play_circle_outline,
          color: Theme.of(context).colorScheme.secondary,
        );
        final box = s.poster;
        final url = posterUrl;
        return SizedBox(
          key: kEpisodeThumbBoxKey,
          width: box.w,
          height: box.h,
          child: (url == null || url.isEmpty)
              ? Center(child: icon)
              : ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CachedImage(
                    url,
                    width: box.w,
                    height: box.h,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Center(child: icon),
                  ),
                ),
        );
      },
    );
  }
}

/// One episode / video row: thumbnail on the left, text and progress on the
/// right (issue #38, item 2).
///
/// Replaces the `TvTile(leading: …)` rows that were duplicated across nine
/// browse screens. It is a custom `Row` rather than a `ListTile` because
/// `ListTile` caps `leading` at 56 px, which is exactly the limit this feature
/// exists to escape. TV focus chrome is preserved by delegating to
/// [TvFocusWrap], so D-pad focus still shows on Fire TV.
///
/// Listens to [LayoutStore] itself, so changing the size in Settings updates
/// every visible row live without any per-screen wiring.
class EpisodeRow extends StatelessWidget {
  const EpisodeRow({
    super.key,
    required this.title,
    this.thumb,
    this.subtitle,
    this.progress,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
  });

  final Widget title;

  /// Thumbnail slot. Prefer [EpisodeStillThumb] / [EpisodePosterThumb] so the
  /// size preference is honoured.
  final Widget? thumb;

  final Widget? subtitle;

  /// Playback progress bar, rendered under the text block.
  final Widget? progress;

  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // Rebuild every row when the layout preference changes.
    return ListenableBuilder(
      listenable: LayoutStore.instance,
      builder: (context, _) {
        final theme = Theme.of(context);
        // Note: `ListTileThemeData` has no titleColor/subtitleColor (those are
        // `ListTile` constructor props), so the text block takes its colours
        // from the same TextTheme styles the app's theme already uses.
        final titleColor = theme.textTheme.titleMedium?.color;
        final subtitleColor = theme.textTheme.bodyMedium?.color;
        final disabled = theme.disabledColor;

        final text = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            DefaultTextStyle.merge(
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: enabled ? titleColor : disabled),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              child: title,
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: DefaultTextStyle.merge(
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: enabled ? subtitleColor : disabled),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  child: subtitle!,
                ),
              ),
            if (progress != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: progress!,
              ),
          ],
        );

        return TvFocusWrap(
          onTap: enabled ? onTap : null,
          onLongPress: enabled ? onLongPress : null,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: enabled ? onTap : null,
              onLongPress: enabled ? onLongPress : null,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight:
                      LayoutStore.instance.thumbSize.rowMinHeight,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: EpisodeThumbGeometry.vPadding,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (thumb != null) ...[
                        thumb!,
                        const SizedBox(width: 12),
                      ],
                      Expanded(child: text),
                      if (trailing != null) ...[
                        const SizedBox(width: 8),
                        trailing!,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
