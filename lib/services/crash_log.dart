import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Crash log for UNCAUGHT Dart errors, written as `dreamplayer_crash.log`
/// next to `app_debug.log` in the app's Documents directory so the Settings
/// "App crashed?" note can send it with the other debug files.
///
/// Two honest limits, so the file is never expected to be more than it is:
/// it records framework/uncaught-async exceptions (FlutterError.onError and
/// PlatformDispatcher.onError), and a NATIVE crash (SIGSEGV in a decoder,
/// watchdog kill) is out of its reach — the OS handles those, which is what
/// .ips reports from Xcode/ASC are for. Behaviour after the error is
/// unchanged: uncaught errors are reported to the console as before.
///
/// Writes are fire-and-forget and never awaited: error handling runs on the
/// broken path already, so the write must never make it slower or throw.
class CrashLog {
  CrashLog._();

  /// The name the "App crashed?" share note looks for.
  static const String fileName = 'dreamplayer_crash.log';

  static const int maxBytes = 256 * 1024;

  /// Off under `flutter test` — a crash aid has no filesystem work in unit
  /// tests and there is no Documents directory there.
  static bool enabled =
      !kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST');

  @visibleForTesting
  static set overrideEnabled(bool value) => enabled = value;

  /// Drops the cached directory/path so the next write re-resolves from
  /// path_provider — each test gets a fresh temp Documents dir.
  @visibleForTesting
  static void resetForTest() {
    _file = null;
    _queue = Future<void>.value();
  }

  static File? _file;
  static Future<void> _queue = Future<void>.value();

  /// Installs the two global handlers. Idempotent; safe to call from main().
  static void install() {
    if (!enabled) return;

    final previousOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      // Console behaviour preserved — dumpErrorToConsole is exactly what the
      // default handler does when onError is null.
      write(details.exceptionAsString(), details.stack);
      FlutterError.dumpErrorToConsole(details);
      if (previousOnError != null) previousOnError(details);
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      write(error.toString(), stack);
      // Not handled: let a fatal error stay fatal.
      return false;
    };
  }

  /// Appends one timestamped entry. Never throws; never blocks the caller.
  static void write(String description, StackTrace? stack) {
    if (!enabled) return;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    final buffer = StringBuffer()
      ..writeln('[$stamp] uncaught error')
      ..writeln(description)
      ..writeln('--- stack ---');
    if (stack != null) {
      buffer.writeln(stack);
    } else {
      buffer.writeln('(no stack trace)');
    }
    buffer.writeln('');
    final entry = buffer.toString();
    _queue = _queue
        .then((_) => _append(entry))
        .catchError((Object _) {/* a crash aid must not crash */});
  }

  static Future<void> _append(String entry) async {
    try {
      var file = _file;
      if (file == null) {
        final dir = await getApplicationDocumentsDirectory();
        file = File('${dir.path}/$fileName');
        _file = file;
      }
      // exists() first: length() throws on a missing file, and the FIRST
      // write is the one that creates the log.
      if (await file.exists() && await file.length() > maxBytes) {
        // Keep the newest half: crash entries are read tail-first.
        final bytes = await file.readAsBytes();
        final trimmed = bytes.sublist(bytes.length -  maxBytes ~/ 2);
        await file.writeAsBytes(trimmed);
      }
      // Flushed: if the process dies moments later (crash or watchdog),
      // the entry must already be on disk — that is the whole point.
      await file.writeAsString(entry, mode: FileMode.append, flush: true);
    } catch (e) {
      // Say so once: a silently broken log is worse than no log.
      _file = null;
      debugPrint('CrashLog: append failed (${e.runtimeType}) — will retry on '
          'the next write');
    }
  }

  /// Forces the buffered write out.
  static Future<void> flush() => _queue;
}
