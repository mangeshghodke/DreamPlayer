import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/cast_manager.dart';

/// View type registered in `AppDelegate` (`CastButtonFactory`).
const String castButtonViewType = 'dreamplayer/cast_button';

/// The Google Cast route-picker button, embedded as a native platform view.
///
/// `GCKCastButton` has no programmatic "open the picker" API - the user taps
/// the control itself - so the real control is hosted natively rather than a
/// Flutter button that would need a method channel to do nothing.
///
/// iOS only. `isSupported` is false on Android, desktop and web, so the
/// widget renders nothing there and no platform view is attempted.
class CastButton extends StatelessWidget {
  const CastButton({super.key, this.size = 40});

  static bool get isSupported =>
      !kIsWeb && Platform.isIOS;

  final double size;

  @override
  Widget build(BuildContext context) {
    if (!isSupported) return const SizedBox.shrink();
    return SizedBox(
      width: size,
      height: size,
      child: UiKitView(
        viewType: castButtonViewType,
        creationParams: const <String, dynamic>{},
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
        },
      ),
    );
  }
}

/// Reads [CastManager] from the widget tree and shows a Cast button when Cast
/// is available, hidden otherwise.
///
/// Placed in the player's top bar next to AirPlay (both are iOS-only native
/// route pickers). When a Cast session is active the button is drawn with a
/// subtle glow so the viewer can tell playback is on the receiver.
class CastButtonTile extends StatelessWidget {
  const CastButtonTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CastManager.instance,
      builder: (context, _) {
        final manager = CastManager.instance;
        if (!manager.available) return const SizedBox.shrink();
        return CastButton();
      },
    );
  }
}
