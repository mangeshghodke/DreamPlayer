import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/crash_log_share.dart';

/// The "App crashed?" note shown beneath the FAQ in Settings: names the
/// debug logs that may exist on the device and hands the existing ones to
/// the platform share sheet, so they can be attached to an email from the
/// user's own mail app.
///
/// iOS-only: the crash reports this note answers come from App Store Connect
/// (TestFlight/App Store builds); Android has no report in the loop, so the
/// row would be talking about nothing there.
class CrashReportNote extends StatelessWidget {
  const CrashReportNote({super.key});

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _send(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
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
    try {
      await shareCrashLogs(paths);
    } catch (e) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open the share sheet. The log files stay in the app '
            "documents folder ('On My iPad / Files' → DreamPlayer on iOS).",
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
        'Froze or closed on its own? Send us the debug files that exist in '
        "DreamPlayer's folder — dreamplayer_crash.log, app_debug.log, "
        'smb_debug.log and/or iap_debug.log. Tapping opens the share sheet '
        'so you can attach them to an email to $supportEmail.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      isThreeLine: true,
      onTap: () => _send(context),
    );
  }
}
