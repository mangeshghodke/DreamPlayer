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

  /// Set when [_bytes] exist but the platform could not DECODE them (truncated
  /// write, a partial download, an image format the decoder rejects).
  ///
  /// Previously that path fell straight through to [widget.errorBuilder], whose
  /// callers draw a near-black icon on a near-black background - so a real
  /// decode failure was indistinguishable from "no image", which is how a
  /// backdrop could appear for a moment and then vanish with the URL still
  /// reachable. Falling back to [Image.network] re-fetches by URL, which is
  /// what the disk cache entry should have been.
  bool _decodeFailed = false;

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
      _decodeFailed = false;
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
        _decodeFailed = false;
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
        _decodeFailed = false;
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
    if (_bytes != null && _decodeFailed) {
      return Image.network(
        widget.url,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: widget.errorBuilder,
      );
    }
    if (_bytes != null) {
      return Image.memory(
        _bytes!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: (context, error, stack) {
          // Bytes are present but undecodable — mark it and fall back to a
          // network fetch of the same URL rather than showing the caller
          // placeholder, which is visually indistinguishable from blank.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_decodeFailed) {
              setState(() => _decodeFailed = true);
            }
          });
          return const SizedBox.shrink();
        },
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
