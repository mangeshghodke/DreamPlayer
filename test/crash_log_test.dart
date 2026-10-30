import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:dream_player/services/crash_log.dart';

/// dreamplayer_crash.log — one timestamped entry per uncaught Dart error,
/// in the app Documents folder, shared by the Settings "App crashed?" note.

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);
  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late File logFile;

  setUp(() {
    docsDir = Directory.systemTemp.createTempSync('crash_log_test');
    PathProviderPlatform.instance = _FakePathProvider(docsDir.path);
    CrashLog.overrideEnabled = true;
    CrashLog.resetForTest();
    logFile = File('${docsDir.path}/${CrashLog.fileName}');
  });

  tearDown(() {
    PathProviderPlatform.instance = PathProviderPlatformFake();
    CrashLog.overrideEnabled = false;
    docsDir.deleteSync(recursive: true);
  });

  test('write appends one timestamped entry with the stack trace', () async {
    CrashLog.write(' boom (test) ', StackTrace.fromString('at test stack line'));
    await CrashLog.flush();

    expect(logFile.existsSync(), isTrue);
    final text = logFile.readAsStringSync();
    expect(text, contains('[20'));
    expect(text, contains('uncaught error'));
    expect(text, contains('boom (test)'));
    expect(text, contains('at test stack line'));
    expect(text, contains('--- stack ---'));
    // The entry is terminated by a blank line, so the next one starts clean.
    expect(text.endsWith('\n\n'), isTrue);
  });

  test('entries accumulate in order', () async {
    CrashLog.write('first loader failure', null);
    CrashLog.write('second loader failure', null);
    await CrashLog.flush();

    final text = logFile.readAsStringSync();
    expect(text.indexOf('first loader failure'),
        lessThan(text.indexOf('second loader failure')));
    // (no stack trace) fills in when the caller had none.
    expect(text, contains('(no stack trace)'));
  });

  test('the file is trimmed from the FRONT once it grows past the cap',
      () async {
    logFile
      ..createSync()
      ..writeAsStringSync('x' * (CrashLog.maxBytes + 4096));
    CrashLog.write('trimmed entry follows the kept tail', null);
    await CrashLog.flush();

    final length = logFile.lengthSync();
    expect(length, lessThan(CrashLog.maxBytes + 1024));
    final text = logFile.readAsStringSync();
    expect(text, contains('trimmed entry follows the kept tail'));
  });

  test('install wires FlutterError.onError to the file', () async {
    final previous = FlutterError.onError;
    addTearDown(() => FlutterError.onError = previous);

    CrashLog.install();
    expect(FlutterError.onError, isNotNull);

    FlutterError.onError!(FlutterErrorDetails(
      exception: StateError('window blown'),
      stack: StackTrace.fromString('at window'),
    ));
    await CrashLog.flush();

    final text = logFile.readAsStringSync();
    expect(text, contains('window blown'));
    expect(text, contains('at window'));
  });
}

/// A deliberately inert stand-in for tearDown hygiene; the fake above is
/// what the payload-producing tests use.
class PathProviderPlatformFake extends PathProviderPlatform {}
