import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Debug logs worth sending home after a crash, by name in the app's
/// documents folder — PER PLATFORM: iOS logs are written by the Swift bridges
/// (`smb_debug.log` by SBMLog, `iap_debug.log` by StoreKit), Android's only
/// extra is `logcat_dump.log`, written on demand by [dumpLogcatIfAndroid] —
/// the only log that can carry a NATIVE crash (SIGSEGV in a decoder,
/// NoSuchMethodError), because CrashLog's Dart handlers never see those.
/// `dreamplayer_crash.log` (uncaught Dart errors, via CrashLog) and
/// `app_debug.log` (AppDebugLog timing traces) are written on both.
const iosCrashLogNames = <String>[
  'dreamplayer_crash.log',
  'app_debug.log',
  'smb_debug.log',
  'iap_debug.log',
];

const androidCrashLogNames = <String>[
  'dreamplayer_crash.log',
  'app_debug.log',
  'logcat_dump.log',
];

/// The attach list for the current platform (or [platform] when given).
List<String> crashLogNamesFor([TargetPlatform? platform]) =>
    (platform ?? defaultTargetPlatform) == TargetPlatform.android
        ? androidCrashLogNames
        : iosCrashLogNames;

const supportEmail = 'ghodke.mangesh2@gmail.com';

const MethodChannel _deviceChannel = MethodChannel('dreamplayer/device');

/// On Android, asks the native side to dump this app's own logcat into the
/// documents folder as `logcat_dump.log` (apps can read their own logs
/// without READ_LOGS since API 16), so the "App crashed?" report can attach
/// it — that is the only place a native/Java crash stack (decoder SIGSEGV,
/// NoSuchMethodError) survives. No-op elsewhere; never throws (a missing
/// handler on iOS/other platforms is fine — the file simply won't exist and
/// the report form lists only files that do).
Future<String?> dumpLogcatIfAndroid() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final dir = await getApplicationDocumentsDirectory();
    final path = await _deviceChannel.invokeMethod<String>(
      'dumpLogcat',
      {'dir': dir.path},
    );
    return path;
  } catch (_) {
    return null;
  }
}

/// The crash logs that actually exist in the app's documents folder, for the
/// current platform's attach list (see [crashLogNamesFor]). Empty when the
/// app has never written a log yet.
Future<List<String>> existingCrashLogPaths({
  Directory? documentsDir,
  TargetPlatform? platform,
}) async {
  final dir = documentsDir ?? await getApplicationDocumentsDirectory();
  final found = <String>[];
  for (final name in crashLogNamesFor(platform)) {
    final file = File('${dir.path}/$name');
    if (file.existsSync()) found.add(file.path);
  }
  return found;
}

/// Opens the platform share sheet with the given log files attached.
/// mailto: cannot carry attachments on either platform, so the share sheet
/// is the route: the user picks their mail app there and addresses it to
/// [supportEmail]. Returns null when there is nothing to share.
Future<ShareResult?> shareCrashLogs(List<String> paths) async {
  if (paths.isEmpty) return null;
  return SharePlus.instance.share(
    ShareParams(
      subject: 'DreamPlayer crash report',
      text: 'DreamPlayer debug logs — reply to $supportEmail.',
      files: paths.map(XFile.new).toList(),
    ),
  );
}
