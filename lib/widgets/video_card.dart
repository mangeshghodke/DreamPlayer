import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/hdr_format.dart';
import '../models/video_item.dart';
import '../services/thumbnail_store.dart';
import '../services/tmdb_client.dart';
import '../utils/codec_info.dart';
import '../utils/tv_helper.dart';

class VideoCard extends StatefulWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.onLongPress,
    this.progress,
    this.subtitle,
    this.tmdbMeta,
    this.downloaded = false,
  });

  final VideoItem video;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Playback progress (0..1) shown as a thin bar, e.g. for Continue watching.
  final double? progress;

  /// Optional label shown under the title, e.g. "Continue from 12:34".
  final String? subtitle;

  /// TMDB metadata (poster/backdrop art, real title, year) when resolved.
  final TmdMeta? tmdbMeta;

  /// Whether this video is downloaded locally.
  final bool downloaded;

  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard> {
  /// Owned focus node handed to the InkWell. Putting focus directly on the
  /// InkWell (rather than a wrapping `Focus`) means D-pad traversal reaches the
  /// card AND `select`/enter activates it through the InkWell's own
  /// ActivateIntent handler. The highlight follows the node via
  /// [ListenableBuilder].
  final FocusNode _focusNode = FocusNode();

  /// TV long-press: hold select/enter for 500 ms to fire [onLongPress].
  /// [onKeyEvent] suppresses ActivateIntent on keyDown and dispatches
  /// manually on keyUp, so touch (non-TV) still works via InkWell normally.
  Timer? _holdTimer;
  bool _longPressFired = false;

  /// Embedded cover-art bytes (poster stored inside the file). Null until
  /// loaded; [_thumbChecked] distinguishes "no art" from "not looked yet".
  Uint8List? _thumb;
  bool _thumbChecked = false;

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = _handleKeyEvent;
    _loadThumb();
  }

  @override
  void didUpdateWidget(covariant VideoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.id != widget.video.id ||
        oldWidget.video.path != widget.video.path) {
      _thumb = null;
      _thumbChecked = false;
      _loadThumb();
    }
  }

  Future<void> _loadThumb() async {
    final bytes = await ThumbnailStore.artFor(widget.video);
    if (mounted) {
      setState(() {
        _thumb = bytes;
        _thumbChecked = true;
      });
    }
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
      return KeyEventResult.handled; // suppress ActivateIntent → no onTap yet
    }
    // Auto-repeat while holding: swallow, or ActivateIntent fires onTap
    // mid-hold (video opens *and* the remove dialog appears).
    if (event is KeyRepeatEvent && _isSelectKey(event)) {
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent && _isSelectKey(event)) {
      _holdTimer?.cancel();
      if (!_longPressFired) {
        widget.onTap(); // manual tap on keyUp
      }
      _longPressFired = false;
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static bool _isSelectKey(KeyEvent e) =>
      e.physicalKey == PhysicalKeyboardKey.enter ||
      e.physicalKey == PhysicalKeyboardKey.select ||
      e.logicalKey == LogicalKeyboardKey.enter ||
      e.logicalKey == LogicalKeyboardKey.select;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final video = widget.video;
    final onTap = widget.onTap;
    final onLongPress = widget.onLongPress;
    final progress = widget.progress;
    final subtitle = widget.subtitle;
    final tmdbMeta = widget.tmdbMeta;
    final source = video.playbackSource;
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
                    AspectRatio(
                      aspectRatio: 16 / 9,
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
                            child: Center(
                              // Play glyph only when there is no art at all —
                              // embedded cover-art or TMDB backdrop replaces
                              // it. Hidden while the art lookup is in flight.
                              child: (!_thumbChecked ||
                                      (_thumb == null &&
                                          tmdbMeta?.movie.backdropUrl() ==
                                              null))
                                  ? const Icon(
                                      Icons.play_circle_outline,
                                      size: 40,
                                      color: Colors.white54,
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                          if (_thumb != null)
                            Image.memory(
                              _thumb!,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                          if (tmdbMeta?.movie.backdropUrl() != null)
                            Image.network(
                              tmdbMeta!.movie.backdropUrl()!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                              loadingBuilder: (context, child, progress) =>
                                  progress == null
                                      ? child
                                      : const SizedBox.shrink(),
                            ),
                          if (video.hdrFormat != HdrFormat.sdr)
                            Positioned(
                              top: 8,
                              left: 8,
                              child: _Badge(
                                label: _hdrShortLabel(video.hdrFormat, video.hdrHint),
                                background: _hdrColor(video.hdrFormat),
                              ),
                            ),
                          if (video.resolution != null && !widget.downloaded)
                            Positioned(
                              top: 8,
                              right: 8,
                              child: _Badge(label: video.resolution!),
                            ),
                          if (widget.downloaded)
                            Positioned(
                              top: 8,
                              right: 8,
                              child: _Badge(
                                label: 'Downloaded',
                                background: Colors.green.shade700,
                              ),
                            ),
                          if (source != null)
                            Positioned(
                              bottom: 8,
                              left: 8,
                              child: _Badge(
                                label: source.label,
                                background: _sourceColor(source),
                              ),
                            ),
                          Positioned(
                            bottom: 8,
                            right: 8,
                            child: _Badge(label: video.durationLabel),
                          ),
                          if (progress != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: LinearProgressIndicator(
                                value: progress.clamp(0.0, 1.0),
                                minHeight: 3,
                                backgroundColor: Colors.black45,
                                color: Colors.white70,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                        child: Column(
                          mainAxisSize: MainAxisSize.max,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (tmdbMeta?.movie.title.isNotEmpty ?? false)
                                  ? tmdbMeta!.movie.title
                                  : video.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            if (subtitle != null)
                              Flexible(
                                child: Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                          color: colorScheme.onSurfaceVariant),
                                ),
                              )
else
                                Flexible(
                                  child: Text(
                                    _subtitleLine(video, tmdbMeta),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                          color:
                                              colorScheme.onSurfaceVariant),
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
          ),
        );
      },
    );
  }

  /// Line under the title when there is no explicit subtitle: year + codec.
  String _subtitleLine(VideoItem video, TmdMeta? tmdbMeta) {
    final parts = <String>[
      if (tmdbMeta?.movie.year != null) '${tmdbMeta!.movie.year}',
      if (video.audioCodecLabel != null) video.audioCodecLabel!,
    ];
    return parts.join(' · ');
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, this.background = Colors.black54});

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

String _hdrShortLabel(HdrFormat format, String? hint) {
  switch (format) {
    case HdrFormat.dolbyVision:
      final p = dolbyVisionProfile(hint);
      if (p != null) return 'DV P$p';
      return 'DV';
    case HdrFormat.hdr10plus:
      return 'HDR10+';
    case HdrFormat.hdr10:
      return 'HDR10';
    case HdrFormat.hlg:
      return 'HLG';
    case HdrFormat.sdr:
      return 'SDR';
  }
}

Color _hdrColor(HdrFormat format) {
  switch (format) {
    case HdrFormat.dolbyVision:
      return const Color(0xFF7C4DFF);
    case HdrFormat.hdr10plus:
      return const Color(0xFFF9A825);
    case HdrFormat.hdr10:
      return const Color(0xFFF57C00);
    case HdrFormat.hlg:
      return const Color(0xFFEF6C00);
    case HdrFormat.sdr:
      return const Color(0xFF616161);
  }
}

Color _sourceColor(PlaybackSource source) {
  switch (source) {
    case PlaybackSource.webdav:
      return const Color(0xFF1565C0);
    case PlaybackSource.cxSmb:
      return const Color(0xFFE65100);
    case PlaybackSource.filesSmb:
      return const Color(0xFF6A1B9A);
    case PlaybackSource.smb:
      return const Color(0xFF6D4C41);
    case PlaybackSource.jellyfin:
      return const Color(0xFF9C27B0);
    case PlaybackSource.files:
      return const Color(0xFF00695C);
    case PlaybackSource.ftp:
      return const Color(0xFF2E7D32);
    case PlaybackSource.network:
      return const Color(0xFF455A64);
  }
}
