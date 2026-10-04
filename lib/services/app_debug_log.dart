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

  /// Set when the last append failed. The very first append happens at boot,
  /// where a plugin channel may not be registered yet — so instead of losing
  /// the line forever, forget the cached File and let the NEXT mark retry. This
  /// was the real reason build 29 produced no file at all: the boot write threw,
  /// the error was swallowed, and every later write inherited the failure.
  static bool _lastAppendFailed = false;

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
    // ${_stamp()} — NOT $_stamp, which interpolates the tear-off and writes
    // "Closure: () => String from Function '_stamp'" into the file instead of
    // a timestamp.
    final line = '${_stamp()}  $message\n';
    _queue = _queue.then((_) => _append(line)).catchError((Object _) {
      _lastAppendFailed = true;
    });
  }

  static Future<void> _append(String line) async {
    try {
      var file = _file;
      if (file == null) {
        final dir = await getApplicationDocumentsDirectory();
        file = File('${dir.path}/app_debug.log');
        _file = file;
      }
      if (_lastAppendFailed) {
        // Last time we failed before a File was ever created, so make sure this
        // one really lands — a log that silently stops is worse than none.
        await file.writeAsString(line, mode: FileMode.append, flush: true);
        _lastAppendFailed = false;
        return;
      }
      if (await file.length() > _maxBytes) {
        // Keep the tail: the newest markers are the ones being read.
        final bytes = await file.readAsBytes();
        final trimmed = bytes.sublist(bytes.length - _maxBytes ~/ 2);
        await file.writeAsBytes(trimmed, flush: false);
      }
      // flush EVERY line. These files are a few KB, and the whole point is to
      // survive exactly the failure we are chasing: with flush:false the tail
      // of the log is lost when the watchdog kills the app mid-investigation,
      // which is precisely when the missing lines matter most.
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (e) {
      // A diagnostics aid must never be the thing that breaks a screen — but
      // do say so once, or a broken writer is indistinguishable from a screen
      // that simply never logged anything (which is exactly how build 29's
      // missing file went unnoticed).
      _file = null;
      _lastAppendFailed = true;
      debugPrint('AppDebugLog: append failed (${e.runtimeType}) — will retry '
          'on the next mark');
    }
  }

  /// Forces buffered lines out — call before backgrounding, if you ever want the
  /// file complete the instant the app is suspended.
  static Future<void> flush() => _queue;
}