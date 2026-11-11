import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the AirPlay / PiP subtitle handoff in `ios/Runner/AvPlayerView.swift`.
///
/// Subtitles render HOST-side: the engine decodes cues into
/// `engine.$subtitleCues` and `AvPlayerView` draws its own
/// `SubtitleOverlayView` over the local `AVPlayerLayer`. When the picture
/// leaves that layer — an AirPlay receiver, the PiP window, a wired external
/// display — the overlay is NOT composited into the stream, so without a
/// handoff the receiver shows video with NO subtitles (the user report:
/// "when I tested airplay video it does not give subtitles").
///
/// The engine's documented host pattern (AetherEngine docs/formats.md,
/// "recommended host pattern for PiP / AirPlay") is: on entering such a
/// surface call `engine.setNativeSubtitleRendering(true)` and hide the host
/// overlay; on leaving call `false` and re-enable it. The engine maps the
/// active overlay track to the matching AVKit legible rendition (bitmap
/// tracks get an OCR-fed text rendition while the rendition is the display),
/// and AVKit then draws the subs on the receiver itself.
///
/// The player screen needs a live platform view, so this cannot be pumped —
/// the wiring is read out of the Swift source instead.
void main() {
  final swift = File('ios/Runner/AvPlayerView.swift').readAsStringSync();

  group('AirPlay/PiP subtitle handoff', () {
    test('host calls setNativeSubtitleRendering on the off-device edges', () {
      expect(swift.contains('engine?.setNativeSubtitleRendering(wants)'), isTrue,
          reason: 'the latched handoff must reach the engine');
      // The three triggers that flip the state: tick timer (catches
      // isExternalPlaybackActive / route flips), route-change observer,
      // PiP delegate, and the per-load settle path.
      expect(swift.contains('self?.updateNativeSubtitleRendering()'), isTrue);
      expect(swift.contains('self.updateNativeSubtitleRendering()'), isTrue);
      final willStart =
          swift.indexOf('func pictureInPictureControllerWillStart');
      final didStop =
          swift.indexOf('func pictureInPictureControllerDidStop');
      expect(
          swift.substring(willStart, willStart + 700)
              .contains('updateNativeSubtitleRendering()'), isTrue,
          reason: 'entering PiP must hand subs to AVKit');
      expect(
          swift.substring(didStop, didStop + 500)
              .contains('updateNativeSubtitleRendering()'), isTrue,
          reason: 'leaving PiP must take subs back');
    });

    test('off-device detection covers PiP, external playback and AirPlay route', () {
      final start = swift.indexOf('private var pictureOffDevice: Bool');
      expect(start, isNot(-1));
      final body = swift.substring(start, start + 600);
      expect(body.contains('if inPip'), isTrue);
      expect(body.contains('isExternalPlaybackActive'), isTrue);
      expect(body.contains('.airPlay'), isTrue,
          reason: 'the audio route survives the engine LAN-swap reload, so '
              'the wireless half must be read from it');
    });

    test('handoff is gated on the native path and hides the host overlay', () {
      expect(swift.contains('nativePathLive && pictureOffDevice'), isTrue,
          reason: 'software path has no AVPlayerItem — AirPlay there is '
              'audio-only and the overlay must stay');
      expect(swift.contains('subtitleOverlay.isHidden = wants'), isTrue,
          reason: 'inline view must not double-draw during the transition');
    });

    test('per-open reset releases the handoff and restores the overlay', () {
      expect(swift.contains('nativeSubtitleRenderingActive = false'), isTrue);
      expect(swift.contains('subtitleOverlay.isHidden = false'), isTrue);
      expect(swift.contains('engine?.setNativeSubtitleRendering(false)'), isTrue);
    });

    test('the decision is logged for on-device verification', () {
      expect(swift.contains('SBMLog.log("native subtitle rendering'), isTrue);
    });
  });
}
