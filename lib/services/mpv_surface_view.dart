import 'dart:async';

import 'package:flutter/foundation.dart' show Factory, immutable;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Distinct viewType for the libmpv SurfaceView — never reuse
/// [exoPlayerViewType] (`dreamplayer/exo_player`).
const String mpvPlayerViewType = 'dreamplayer/mpv_player';

/// Dart handle to the native mpv [SurfaceView].
///
/// Native reports `surfaceReady` / `surfaceChanged` / `surfaceLost` on
/// `dreamplayer/mpv_<viewId>`. Callers wait for [waitUntilReady], then set
/// mpv `--wid` to [wid] (media_kit property order).
class MpvSurfaceViewController {
  MethodChannel? _method;
  int? _wid;
  int _width = 0;
  int _height = 0;
  Completer<void>? _ready;

  /// Called when the Android Surface exists (or was recreated with a new size).
  void Function(int wid, int width, int height)? onSurfaceReady;

  /// Called when the Surface is gone (destroy / dispose) — clear `--wid`.
  void Function()? onSurfaceLost;

  int? get wid => _wid;
  int get width => _width;
  int get height => _height;
  bool get isReady => _wid != null && _wid! > 0 && _width > 0 && _height > 0;

  /// Completes when the surface is ready (immediately if already attached).
  Future<void> waitUntilReady({
    Duration timeout = const Duration(seconds: 10),
  }) {
    if (isReady) return Future<void>.value();
    final c = _ready ??= Completer<void>();
    return c.future.timeout(timeout);
  }

  void attach(int viewId) {
    final method = MethodChannel('dreamplayer/mpv_$viewId');
    _method = method;
    method.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'surfaceReady':
        case 'surfaceChanged':
          final args = call.arguments;
          if (args is! Map) return null;
          final wid = (args['wid'] as num?)?.toInt() ?? 0;
          final w = (args['width'] as num?)?.toInt() ?? 0;
          final h = (args['height'] as num?)?.toInt() ?? 0;
          final sizeChanged = w != _width || h != _height;
          _wid = wid;
          _width = w;
          _height = h;
          if (wid > 0 && w > 0 && h > 0) {
            final c = _ready;
            if (c != null && !c.isCompleted) c.complete();
            onSurfaceReady?.call(wid, w, h);
          } else if (sizeChanged) {
            // Defensive: zero-size ready is not usable.
          }
          return null;
        case 'surfaceLost':
          final had = _wid != null && _wid! > 0;
          _wid = 0;
          _width = 0;
          _height = 0;
          _ready = null;
          if (had) onSurfaceLost?.call();
          return null;
      }
      return null;
    });
    if (isReady) {
      final c = _ready;
      if (c != null && !c.isCompleted) c.complete();
      onSurfaceReady?.call(_wid!, _width, _height);
    }
  }

  void dispose() {
    _method?.setMethodCallHandler(null);
    _method = null;
    _wid = null;
    _width = 0;
    _height = 0;
    _ready = null;
    onSurfaceReady = null;
    onSurfaceLost = null;
  }
}

/// Embeds the libmpv [SurfaceView] via **hybrid composition**
/// ([PlatformViewLink] + [PlatformViewsService.initExpensiveAndroidView]) —
/// same pattern as [ExoPlayerView]. Never mounted alongside Media3.
@immutable
class MpvSurfaceView extends StatelessWidget {
  const MpvSurfaceView({super.key, required this.controller});

  final MpvSurfaceViewController controller;

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: mpvPlayerViewType,
      surfaceFactory:
          (BuildContext context, PlatformViewController controller) {
            return AndroidViewSurface(
              controller: controller as AndroidViewController,
              gestureRecognizers:
                  const <Factory<OneSequenceGestureRecognizer>>{},
              hitTestBehavior: PlatformViewHitTestBehavior.opaque,
            );
          },
      onCreatePlatformView: (PlatformViewCreationParams params) {
        final AndroidViewController nativeController =
            PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: params.viewType,
              layoutDirection: TextDirection.ltr,
            );
        nativeController
          ..addOnPlatformViewCreatedListener(controller.attach)
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
        return nativeController;
      },
    );
  }
}
