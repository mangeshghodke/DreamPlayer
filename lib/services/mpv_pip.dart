import 'dart:io';

import 'package:flutter/services.dart';

/// Picture-in-picture bridge for the **libmpv fallback engine** (Android only).
///
/// The main Media3 engine handles pip inside its own platform view: it owns the
/// `SurfaceView` and the live `ExoPlayer`, so the native side can decide alone.
/// In mpv mode the native pip path still gates on ExoPlayer (idle), so it would
/// silently refuse — this bridge takes over.
///
/// Entering pip is an Activity-level operation: the whole Flutter window
/// shrinks into the pip window, and the player screen already hides all chrome
/// while `_inPip` is set.
///
/// Automatic entry is decided in `onUserLeaveHint`, which cannot await a
/// round-trip to Dart — so playback state is PUSHED down via [setState]
/// whenever it changes, and the native side answers synchronously.
class MpvPipService {
  MpvPipService._();

  static final MpvPipService instance = MpvPipService._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/pip');

  /// Called when the system moves the app in/out of pip while the fallback
  /// engine owns playback.
  void Function(bool inPip)? onPipChanged;

  /// Called when the user swipes the pip window away — the screen should pause.
  void Function()? onPipDismissed;

  /// The pip window's transport buttons. The floating window shows only the
  /// video (no Flutter chrome), so these system-drawn `RemoteAction`s are the
  /// only way to control playback there.
  void Function()? onPlayPause;
  void Function()? onRewind;
  void Function()? onForward;

  bool _handlerInstalled = false;

  /// Only Android has picture-in-picture in this app (iOS pip is handled by
  /// `AVPictureInPictureController` in the native AVPlayer path, which the
  /// fallback engine does not use).
  bool get _supported => Platform.isAndroid;

  void _ensureHandler() {
    if (_handlerInstalled || !_supported) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'pipChanged':
          final args = call.arguments;
          final inPip =
              args is Map ? (args['inPip'] as bool? ?? false) : false;
          onPipChanged?.call(inPip);
          return null;
        case 'pipDismissed':
          onPipDismissed?.call();
          return null;
        case 'pipPlayPause':
          onPlayPause?.call();
          return null;
        case 'pipRewind':
          onRewind?.call();
          return null;
        case 'pipForward':
          onForward?.call();
          return null;
      }
      return null;
    });
  }

  /// Pushes the fallback engine's playback state to the native side.
  ///
  /// [aspect] is width / height; pass 0 when unknown (16:9 is assumed).
  Future<void> setState({
    required bool active,
    required bool playing,
    double aspect = 0,
  }) async {
    if (!_supported) return;
    _ensureHandler();
    try {
      await _channel.invokeMethod<void>('setMpvState', {
        'active': active,
        'playing': playing,
        'aspect': aspect,
      });
    } on PlatformException {
      // Channel missing (older build / non-Android): pip just stays off.
    } on MissingPluginException {
      // Same.
    }
  }

  /// Explicit entry (⋮ sheet row). Returns true when pip was requested.
  Future<bool> enterPip() async {
    if (!_supported) return false;
    _ensureHandler();
    try {
      return await _channel.invokeMethod<bool>('enterPip') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Drops the callbacks so a disposed player screen never receives events.
  void clear() {
    onPipChanged = null;
    onPipDismissed = null;
    onPlayPause = null;
    onRewind = null;
    onForward = null;
  }
}
