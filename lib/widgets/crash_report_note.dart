import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/crash_log_share.dart';
import '../services/crash_report_upload.dart';
import 'crash_report_dialog.dart';

/// The "App crashed?" note shown beneath the FAQ in Settings: names the
/// debug logs that may exist on the device and sends them from an in-app
/// popup (file checkboxes + message + Submit) to the configured upload
/// endpoint. When no endpoint is configured — or the upload fails — it
/// falls back to the platform share sheet, so they can be attached to an
/// email from the user's own mail app.
///
/// Both platforms: on iOS the reports answer App Store Connect crashes; on
/// Android the note first dumps the app's own logcat (`logcat_dump.log`),
/// which is the only log that carries native/Java crashes (decoder SIGSEGV,
/// NoSuchMethodError) — CrashLog's Dart handlers never see those.
class CrashReportNote extends StatelessWidget {
  const CrashReportNote({super.key});

  static bool get isSupported => !kIsWeb;

  Future<void> _send(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    // Android: refresh the logcat dump FIRST so the freshest crash is in the
    // file the form is about to list.
    await dumpLogcatIfAndroid();
    final paths = await existingCrashLogPaths();
    if (paths.isEmpty) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text(
            'No debug logs have been written yet. Use the app a little and try again.',
          ),
        ),
      );
      return;
    }
    if (CrashReportUpload.isConfigured) {
      if (!context.mounted) return;
      await showCrashReportDialog(context);
      return;
    }
    try {
      await shareCrashLogs(paths);
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            defaultTargetPlatform == TargetPlatform.iOS
                ? 'Could not open the share sheet. The log files stay in the '
                    "app documents folder ('On My iPad / Files' → DreamPlayer)."
                : 'Could not open the share sheet. The report form can still '
                    'attach the logs if an upload endpoint is configured.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isSupported) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      leading: Icon(
        Icons.bug_report,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: const Text('App crashed?', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        defaultTargetPlatform == TargetPlatform.android
            ? 'Froze or crashed? Attach the debug logs (logcat included) and '
                'send them to us.'
            : 'Froze or crashed? Attach the debug logs and send them to '
                '$supportEmail.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      isThreeLine: true,
      onTap: () => _send(context),
    );
  }
}
