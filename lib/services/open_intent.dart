import 'dart:async';

import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../utils/file_info_extractor.dart';

/// Represents a video handed to the app via an Android "Open with" intent.
class OpenIntent {
  const OpenIntent({required this.title, this.uri, this.path});

  final String title;
  final String? uri;
  final String? path;

  VideoItem toVideoItem() {
    final fi = extractFileInfo(title);
    return VideoItem(
      id: 'intent_${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      path: path,
      uri: uri,
      resumeKey: _stableResumeKey(path: path, uri: uri),
      duration: Duration.zero,
      videoCodec: fi.videoCodec,
      audioCodec: fi.audioCodec,
      audioChannels: fi.audioChannels,
      resolution: fi.resolution,
      hdrHint: fi.hdrHint,
    );
  }
}

/// Derives a resume key that survives between sessions for sources whose
/// playable URL rotates. Returns null when the regular path/URI fallback is
/// already stable.
String? _stableResumeKey({String? path, String? uri}) {
  // CX Explorer streams SMB videos through its own local HTTP proxy
  // (`http://127.0.0.1:<port>/SMB/<server>/<share>/<file>`); the port changes
  // every CX session, so key on the (stable) path portion only.
  if (uri != null) {
    final u = Uri.tryParse(uri);
    if (u != null &&
        (u.host == '127.0.0.1' || u.host == 'localhost') &&
        (u.scheme == 'http' || u.scheme == 'https') &&
        u.path.contains('/SMB/')) {
      return 'cx:${u.path}';
    }
  }
  return null;
}

/// Bridges the native `dreamplayer/intent` channel (see `MainActivity.kt`):
/// receives videos opened from file explorers / "Open with" menus.
class OpenIntentService {
  OpenIntentService._();

  static final OpenIntentService instance = OpenIntentService._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/intent');

  final StreamController<OpenIntent> _controller =
      StreamController<OpenIntent>.broadcast();

  Stream<OpenIntent> get intents => _controller.stream;

  bool _initialized = false;

  /// Sets up the channel listener. [onOpen] is invoked for every intent that
  /// arrives (including one that launched the app), before [intents] is added.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open') {
        // A launcher re-launch (singleTop) delivers `onNewIntent` with a MAIN
        // intent; the native side maps non-video intents to a null payload
        // (see MainActivity.kt). Ignore those instead of pushing the player
        // with no source.
        final args = call.arguments;
        if (args is! Map) return;
        final intent = OpenIntent(
          title: (args['title'] as String?) ?? 'Video',
          uri: args['uri'] as String?,
          path: args['path'] as String?,
        );
        _controller.add(intent);
      }
    });

    Map<dynamic, dynamic>? initial;
    try {
      initial = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getInitialIntent',
      );
    } on MissingPluginException {
      // No intent channel available — nothing to pick up.
      initial = null;
    }
    if (initial != null) {
      final intent = OpenIntent(
        title: (initial['title'] as String?) ?? 'Video',
        uri: initial['uri'] as String?,
        path: initial['path'] as String?,
      );
      _controller.add(intent);
    }
  }
}