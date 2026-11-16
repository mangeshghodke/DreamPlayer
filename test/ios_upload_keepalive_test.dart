import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// iOS suspends an app on screen lock unless a declared background mode is
/// active. `audio` is declared in Info.plist but only counts while audio is
/// playing, so UploadServer plays a looping silent buffer through an active
/// playback session while the upload server runs. These tests pin the wiring
/// (the Swift side cannot be compiled here, so the sources are read).
void main() {
  final swift =
      File('ios/Runner/UploadServer.swift').readAsStringSync();
  final plist = File('ios/Runner/Info.plist').readAsStringSync();
  final kt = File(
    'android/app/src/main/kotlin/com/dreamplayer/app/UploadServer.kt',
  ).readAsStringSync();
  final screen =
      File('lib/screens/wifi_transfer_screen.dart').readAsStringSync();

  test('Info.plist declares the audio background mode', () {
    expect(plist, contains('<key>UIBackgroundModes</key>'));
    expect(plist, contains('<string>audio</string>'));
  });

  test('UploadServer plays a looping silent buffer while running', () {
    expect(swift, contains('import AVFoundation'));
    expect(swift, contains('AVAudioPlayer'));
    expect(swift, contains('numberOfLoops = -1'));
    // Playback category + mixWithOthers so video playback is not interrupted.
    expect(swift, contains('.playback'));
    expect(swift, contains('.mixWithOthers'));
    // Silence is generated in memory, not shipped as an asset.
    expect(swift, contains('silentWav'));
  });

  test('keep-alive starts with the server and stops with it', () {
    final startBody = swift.substring(
      swift.indexOf('private func start('),
      swift.indexOf('private func stop()'),
    );
    expect(startBody, contains('startKeepAlive()'));
    final stopBody = swift.substring(swift.indexOf('private func stop()'));
    expect(stopBody, contains('stopKeepAlive()'));
    // A listener that fails mid-run must tear the keep-alive down too.
    expect(swift, contains('self?.stop()'));
  });

  test('stop does not deactivate the shared audio session (would pause video)', () {
    final stopBody = swift.substring(swift.indexOf('private func stop()'));
    final keepAlive = stopBody.substring(
      stopBody.indexOf('private func stopKeepAlive()'),
    );
    // A call would be `.setActive(false`; the comment mentions it without the dot.
    expect(keepAlive, isNot(contains('.setActive(false')));
  });

  test('both webpages and the app screen say the server survives lock', () {
    expect(swift, contains('even when the screen is locked'));
    expect(kt, contains('even when the screen is locked'));
    expect(screen, contains('while the screen is locked'));
  });
}
