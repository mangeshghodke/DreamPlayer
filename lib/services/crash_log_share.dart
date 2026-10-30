import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Debug logs worth sending home after a crash, by name in the app's
/// documents folder. `dreamplayer_crash.log` is written by CrashLog whenever
/// an uncaught Dart error is thrown; which of the others exist varies per
/// session: `app_debug.log` is written by AppDebugLog (playback/timing
/// traces), `smb_debug.log` by the SMB bridge, `iap_debug.log` by StoreKit.
const crashLogNames = <String>[
  'dreamplayer_crash.log',
  'app_debug.log',
  'smb_debug.log',
  'iap_debug.log',
];

const supportEmail = 'ghodke.mangesh2@gmail.com';

/// The crash logs that actually exist in the app's documents folder.
/// Empty when the app has never written a log yet.
Future<List<String>> existingCrashLogPaths({Directory? documentsDir}) async {
  final dir = documentsDir ?? await getApplicationDocumentsDirectory();
  final found = <String>[];
  for (final name in crashLogNames) {
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
