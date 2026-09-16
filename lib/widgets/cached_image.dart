import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/image_cache_service.dart';

/// Drop-in replacement for [Image.network] that serves images from a permanent
/// on-disk cache first, falling back to network only when the image isn't
/// cached yet. Identical API surface to the common [Image.network] usage
/// across the app (fit, width, height, errorBuilder, loadingBuilder).
class CachedImage extends StatefulWidget {
  const CachedImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.errorBuilder,
    this.loadingBuilder,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final ImageErrorWidgetBuilder? errorBuilder;
  final Widget Function(BuildContext, Widget, ImageChunkEvent?)? loadingBuilder;

  @override
  State<CachedImage> createState() => _CachedImageState();
}

class _CachedImageState extends State<CachedImage> {
  Uint8List? _bytes;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CachedImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      // Keep the old poster visible while the new one loads — don't clear
      // _bytes to placeholder.  The new fetch will replace it on success;
      // on failure (offline) the stale poster stays instead of going blank.
      _error = false;
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.url;
    // Check memory/disk cache first (fast path — no network).
    final cached = await ImageCacheService.instance.getCached(url);
    if (!mounted || widget.url != url) return;
    if (cached != null) {
      setState(() {
        _bytes = cached;
        _error = false;
      });
      return;
    }
    // Not cached — download from network.
    final bytes = await ImageCacheService.instance.fetch(url);
    if (!mounted || widget.url != url) return;
    if (bytes != null) {
      setState(() {
        _bytes = bytes;
        _error = false;
      });
    } else {
      // Offline or fetch failed — keep the previous poster (_bytes) if any
      // instead of flipping to error/blank.  Only show error when we never
      // had an image for this card.
      if (_bytes == null) {
        setState(() => _error = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      if (widget.errorBuilder != null) {
        return widget.errorBuilder!(
          context,
          Exception('Failed to load image'),
          StackTrace.current,
        );
      }
      return const SizedBox.shrink();
    }
    if (_bytes != null) {
      return Image.memory(
        _bytes!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: widget.errorBuilder,
      );
    }
    if (widget.loadingBuilder != null) {
      return widget.loadingBuilder!(
        context,
        const SizedBox.shrink(),
        null,
      );
    }
    return const SizedBox.shrink();
  }
}
