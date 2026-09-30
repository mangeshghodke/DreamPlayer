import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/thumbnail_store.dart';
import '../services/tmdb_client.dart';
import '../widgets/cached_image.dart';

/// One wide row for the library's list view.
///
/// The grids only ever receive a *finished card* from their callers, so a
/// list view cannot be faked by squeezing a poster card into a wide slot —
/// each caller supplies its own artwork widget and this renders the row
/// chrome (art, title, subtitle, optional trailing widget) plus the D-pad
/// focus highlight used everywhere else in the app.
class LibraryListRow extends StatelessWidget {
  const LibraryListRow({
    super.key,
    required this.title,
    required this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
  });

  final String title;
  final Widget leading;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(width: 54, height: 78, child: leading),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null && subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.textTheme.bodySmall?.color
                                ?.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Row artwork for a video: the file's own embedded cover art when it has
/// one, otherwise the TMDB backdrop — the same precedence [VideoCard] uses.
class VideoRowArt extends StatefulWidget {
  const VideoRowArt({super.key, required this.video, this.tmdbMeta});

  final VideoItem video;
  final TmdMeta? tmdbMeta;

  @override
  State<VideoRowArt> createState() => _VideoRowArtState();
}

class _VideoRowArtState extends State<VideoRowArt> {
  Uint8List? _bytes;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant VideoRowArt old) {
    super.didUpdateWidget(old);
    if (old.video.resumeKey != widget.video.resumeKey ||
        old.video.path != widget.video.path) {
      _bytes = null;
      _checked = false;
      _load();
    }
  }

  Future<void> _load() async {
    final bytes = await ThumbnailStore.artFor(widget.video);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _checked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const ColoredBox(
        color: Color(0xFF16161A),
        child: Center(
          child: Icon(Icons.play_circle_outline,
              size: 22, color: Colors.white38),
        ),
      );
    }
    final backdrop = widget.tmdbMeta?.movie.backdropUrl();
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_bytes != null)
          Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true),
        if (backdrop != null)
          CachedImage(
            backdrop,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : const SizedBox.shrink(),
          ),
      ],
    );
  }
}

/// Row artwork for a library folder: the TMDB poster, or a folder glyph.
class FolderRowArt extends StatelessWidget {
  const FolderRowArt({super.key, this.meta});

  final TmdMeta? meta;

  @override
  Widget build(BuildContext context) {
    final poster = posterUrlOf(meta);
    if (poster == null) {
      return ColoredBox(
        color: const Color(0xFF16161A),
        child: const Center(
          child: Icon(Icons.folder_outlined, size: 24, color: Colors.white38),
        ),
      );
    }
    return CachedImage(
      poster,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : const SizedBox.shrink(),
    );
  }
}
