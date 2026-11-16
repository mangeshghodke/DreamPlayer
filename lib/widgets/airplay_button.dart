import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// View type registered in `AppDelegate` (`AirPlayButtonFactory`).
const String airPlayViewType = 'dreamplayer/airplay';

/// The system AirPlay route picker, embedded as a platform view.
///
/// iOS only. `AVRoutePickerView` has no programmatic presentation API, so the
/// real control is hosted natively instead of a button that would need a
/// method channel to do nothing.
///
/// Note the engine split: the native AVPlayer path (Apple containers) can
/// send the *picture* to a receiver, while the FFmpeg/Metal path (MKV, TS,
/// AVI, WebM) can only route audio - AirPlay video needs an `AVPlayerLayer`.
/// The picker is shown either way, because audio-only AirPlay to a HomePod or
/// receiver is still useful.
class AirPlayButton extends StatelessWidget {
  const AirPlayButton({super.key, this.size = 40});

  /// False on Android, desktop and in widget tests, where the platform view
  /// type does not exist - building a [UiKitView] there would never resolve.
  static bool get isSupported => !kIsWeb && Platform.isIOS;

  final double size;

  @override
  Widget build(BuildContext context) {
    if (!isSupported) return const SizedBox.shrink();
    return SizedBox(
      width: size,
      height: size,
      child: UiKitView(
        viewType: airPlayViewType,
        creationParams: const <String, dynamic>{},
        creationParamsCodec: const StandardMessageCodec(),
        // Without this the Flutter gesture arena keeps the tap and the
        // native picker never opens: the platform view is one widget in a
        // stack of gesture detectors (tap-to-reveal, swipe-to-seek).
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
        },
      ),
    );
  }
}
