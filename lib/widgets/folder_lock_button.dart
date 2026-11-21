import 'package:flutter/material.dart';

import '../services/app_lock_store.dart';

/// Lock/unlock toggle for a single library folder (app lock, competitor-gap
/// #8). Shows a lock icon in the screen's AppBar; tapping it asks for the
/// device credential before locking (so a folder can never be locked without
/// a way back in), and clears the lock on unlock.
///
/// Shown on every screen that represents a library folder: FolderScreen,
/// SeriesSeasonsScreen and TmdDetailsScreen (folder mode).
class FolderLockButton extends StatelessWidget {
  const FolderLockButton({super.key, required this.folderId});

  final String folderId;

  Future<void> _toggle(BuildContext context, bool currentlyLocked) async {
    final ok =
        await AppLockStore.instance.setFolderLocked(folderId, !currentlyLocked);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? (currentlyLocked ? 'Folder unlocked' : 'Folder locked')
            : 'Authentication cancelled - folder not locked'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLockStore.instance,
      builder: (context, _) {
        final locked = AppLockStore.instance.lockedFolderIds.contains(folderId);
        return IconButton(
          tooltip: locked ? 'Unlock folder' : 'Lock folder',
          icon: Icon(locked ? Icons.lock : Icons.lock_open),
          onPressed: () => _toggle(context, locked),
        );
      },
    );
  }
}
