import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Requests every runtime permission the app needs at first open, so a
/// video never has to open behind a permission dialog.
///
/// - Photos & videos (READ_MEDIA_VIDEO / legacy storage): system dialog.
/// - Notifications (POST_NOTIFICATIONS, Android 13+): system dialog — needed
///   for the background-playback media notification.
/// - All Files Access (MANAGE_EXTERNAL_STORAGE): a special permission with no
///   system dialog; an in-app explainer (shown once per install) routes to
///   the system page. Needed for the file browser, bookmarked folders and
///   sibling-subtitle auto-pairing.
///
/// Called on every app open: granted permissions return instantly, so this
/// is only visible on a fresh install or after a manual revocation. The
/// video-open flow keeps its own fallback requests.
Future<void> requestStartupPermissions(BuildContext context) async {
  if (!Platform.isAndroid) return;
  try {
    await Permission.videos.request();
    await Permission.notification.request();

    if (await Permission.manageExternalStorage.isGranted) return;
    final prefs = await SharedPreferences.getInstance();
    const flag = 'dreamplayer.allFilesDialogShown';
    if (prefs.getBool(flag) == true) return;
    if (!context.mounted) return;
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Allow all files access?'),
        content: const Text(
          'Needed to browse your storage and play videos from any folder.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    await prefs.setBool(flag, true);
    if (open == true) {
      await Permission.manageExternalStorage.request();
    }
  } catch (_) {
    // Permissions are best-effort at startup; the video-open flow re-asks.
  }
}
