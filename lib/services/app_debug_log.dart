import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Dart-side debug log, written next to `smb_debug.log` in the app's Documents
/// directory so it can be pulled off the device the same way
/// (Files -> On My iPad -> DreamPlayer -> app_debug.log).
///
/// WHY THIS EXISTS: the native SMB log proved it could not answer the
/// "first details screen hangs on iOS" question — that delay has no SMB traffic
/// in it at all (a 10.5s gap containing zero channel calls), so the missing
/// time is Dart-side. The timing markers that would show it were `debugPrint`,
/// which on a TestFlight build only reaches a device console — and there is no
/// Mac in the loop to read one. A file is the only channel that actually reaches
/// the person debugging.
///
/// Writes are fire-and-forget and never awaited on the UI path: an unawaited
/// append cannot block the isolate, and [mark] deliberately has no `Future` to
/// await. The file is capped by truncating in place once it grows past
/// [_maxBytes], so it cannot grow without bound.
class AppDebugLog {
  AppDebugLog._();

  static const int _maxBytes = 256 * 1024;

  /// Off under `flutter test` (no real Documents directory, and a diagnostics
  /// aid has no business doing filesystem work in a unit test). Everywhere else
  /// it is on — the whole point is to have the file on the device.
  static bool enabled = !kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST');

  /// Visible for tests that want to exercise the writer against a temp dir.
  @visibleForTesting
  static set overrideEnabled(bool value) => enabled = value;

  static File? _file;
  static Future<void> _queue = Future<void>.value();

  static String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
        '.${now.millisecond.toString().padLeft(3, '0')}';
  }

  /// Appends one timestamped line. Returns immediately.
  static void mark(String message) {
    if (!enabled) return;
    debugPrint(message);
    final line = '$_stamp  $message\n';
    _queue = _queue.then((_) => _append(line)).catchError((Object _) {});
  }

  static Future<void> _append(String line) async {
    try {
      var file = _file;
      if (file == null) {
        final dir = await getApplicationDocumentsDirectory();
        file = File('${dir.path}/app_debug.log');
        _file = file;
      }
      if (await file.length() > _maxBytes) {
        // Keep the tail: the newest markers are the ones being read.
        final bytes = await file.readAsBytes();
        final trimmed = bytes.sublist(bytes.length - _maxBytes ~/ 2);
        await file.writeAsBytes(trimmed, flush: false);
      }
      await file.writeAsString(line, mode: FileMode.append, flush: false);
    } catch (_) {
      // A diagnostics aid must never be the thing that breaks a screen.
    }
  }

  /// Forces buffered lines out — call before backgrounding, if you ever want the
  /// file complete the instant the app is suspended.
  static Future<void> flush() => _queue;
}