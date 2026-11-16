/// Mount-point tests for Android storage paths.
///
/// Internal storage is `/storage/emulated/...` (and the `/storage/self/...`
/// symlink to it); every other real volume - SD card, USB drive - mounts at
/// `/storage/<UUID>`. Judging by the mount point rather than a platform flag is
/// deliberate: `Environment.isExternalStorageManager()` says nothing about
/// WHICH volume, and asking Dart for that per file would be a round trip for
/// something the path already tells us.
///
/// This used to be a private getter on the details screen and inline logic in
/// the file browser. Two copies of "is this removable?" is how they drift, so it
/// lives here and both call it.
library;

/// True when [path] is on a removable volume - an SD card or a USB drive.
///
/// Unmounted or unknown paths (a SAF `content://` URI or a synthetic
/// `tree:<id>`) are NOT removable: neither can be proven to be, and guessing
/// "removable" would offer actions on something that cannot be copied.
bool isOnRemovableStorage(String? path) {
  if (path == null || path.isEmpty) return false;
  if (path.startsWith('content://') || path.startsWith('tree:')) return false;
  if (!path.startsWith('/storage/') && !path.startsWith('/sdcard/')) {
    return false;
  }
  return !path.startsWith('/storage/emulated/') &&
      !path.startsWith('/storage/self/');
}

/// True when [path] is on the device's own internal storage.
bool isInternalStorage(String? path) {
  if (path == null || path.isEmpty) return false;
  return path.startsWith('/storage/emulated/') ||
      path.startsWith('/storage/self/');
}