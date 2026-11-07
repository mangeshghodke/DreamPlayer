import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// A directory/file entry returned by the native file browser.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    this.bookmarkId,
    this.resumeKey,
    this.isFilesHome = false,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;

  /// Non-null for folders picked via the system folder picker (bookmarked).
  final String? bookmarkId;

  /// Stable identity for the resume feature, present for files that live
  /// inside a bookmarked folder (iOS). Falls back to [path]/[uri] when null.
  final String? resumeKey;

  /// True for the virtual "Files" root (iOS): tapping it opens the system
  /// document picker — the real Files-app home — instead of listing a path.
  final bool isFilesHome;

  factory FileEntry.fromMap(Map<dynamic, dynamic> map) {
    return FileEntry(
      name: (map['name'] as String?) ?? '',
      path: (map['path'] as String?) ?? '',
      isDirectory: (map['isDirectory'] as bool?) ?? false,
      size: (map['size'] as num?)?.toInt() ?? 0,
      bookmarkId: map['bookmarkId'] as String?,
      resumeKey: map['resumeKey'] as String?,
      isFilesHome: (map['isFilesHome'] as bool?) ?? false,
    );
  }
}

/// Wraps the native `dreamplayer/files` channel (see `FileBrowser.kt`).
class FileBrowserService {
  FileBrowserService._();

  static final FileBrowserService instance = FileBrowserService._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/files');

  /// True when the app can freely read the whole filesystem
  /// (always true below Android 11 and on iOS).
  Future<bool> hasAllFilesAccess() async {
    final result = await _channel.invokeMethod<bool>('hasAllFilesAccess');
    return result ?? false;
  }

  /// Launches the system "All files access" settings page for this app.
  Future<void> openAllFilesAccessSettings() async {
    await _channel.invokeMethod<void>('openAllFilesAccessSettings');
  }

  /// Storage roots (internal storage, SD card) shown at the top level.
  Future<List<FileEntry>> storageRoots() async {
    final result = await _channel.invokeListMethod<dynamic>('getStorageRoots');
    if (result == null) return const [];
    return result
        .map((e) => FileEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Copies a local file or folder into `<Downloads>/DreamPlayer/`.
  ///
  /// Returns the destination path, or null on success / a message on failure.
  /// Mirrors [deleteLocalFile]'s contract so callers handle both the same way.
  Future<String?> copyLocalToDownloads(String path) async {
    if (path.isEmpty) return 'Nothing to copy';
    if (!Platform.isAndroid) return 'Copying is only supported on Android';
    try {
      // The native side answers with the DESTINATION PATH (a String), not a
      // bool. Reading it as <bool> and testing `== true` made every copy report
      // failure — a silent mismatch that only showed up as a red snackbar.
      final destination =
          await _channel.invokeMethod<String>('copyLocalToDownloads', {
        'path': path,
      });
      if (destination == null || destination.isEmpty) {
        return 'The item could not be copied';
      }
      return null;
    } on PlatformException catch (e) {
      return switch (e.code) {
        'no_permission' =>
          'DreamPlayer needs All Files Access to copy files.',
        'not_found' => 'That item no longer exists.',
        _ => e.message ?? 'The item could not be copied.',
      };
    } catch (_) {
      return 'The item could not be copied';
    }
  }

  /// Directories (first) and video files inside [path].
  /// Why the most recent [listDirectory] came back empty, if it failed.
  ///
  /// The native side used to answer a failed listing with a single
  /// `{"error": ...}` pseudo-entry that this method silently dropped, so an
  /// unreadable folder was indistinguishable from an empty one — and adding
  /// one looked like a no-op. The reason is now retained so callers can
  /// explain the failure.
  String? lastListError;

  /// Human-readable text for [lastListError].
  String? get lastListErrorText => switch (lastListError) {
        'no_permission' =>
          'iOS refused access to that location. If it is an external drive, '
              'reconnect it and pick the folder again.',
        'stale_bookmark' =>
          'That folder is on a drive iOS can no longer grant access to. '
              'Reconnect the drive and add the folder again.',
        'not_found' =>
          'That folder could not be opened. Check it is still connected.',
        _ => null,
      };

  Future<List<FileEntry>> listDirectory(String path) async {
    final result = await _channel.invokeListMethod<dynamic>('listDirectory', {
      'path': path,
    });
    if (result == null) {
      lastListError = null;
      return const [];
    }
    String? error;
    final entries = <FileEntry>[];
    for (final e in result) {
      final map = e as Map<dynamic, dynamic>;
      final err = map['error'];
      if (err != null) {
        error ??= err.toString();
        continue;
      }
      entries.add(FileEntry.fromMap(map));
    }
    lastListError = error;
    return entries;
  }

  /// Permanently deletes a **local** file.
  ///
  /// Android only, and only for a plain filesystem path or a `content://` SAF
  /// URI. Network sources are refused natively — deleting from a NAS share
  /// needs protocol-level support this app deliberately does not have, and a
  /// mis-fired tap there is irreversible.
  ///
  /// [path] carries both cases: the native listing returns a plain absolute
  /// path for direct files and the document URI itself for SAF tree entries.
  /// Returns null on success, or a human-readable reason it could not be done.
  Future<String?> deleteLocalFile(String path) async {
    if (path.isEmpty) return 'Nothing to delete';
    if (!Platform.isAndroid) {
      return 'Deleting files is only supported on Android';
    }
    try {
      final isSaf = path.startsWith('content://');
      final ok = await _channel.invokeMethod<bool>('deleteLocalFile', {
        if (isSaf) 'uri': path else 'path': path,
      });
      if (ok == true) return null;
      return 'The file could not be deleted';
    } on PlatformException catch (e) {
      return switch (e.code) {
        'no_permission' =>
          'DreamPlayer needs All Files Access to delete local files.',
        'unsupported' =>
          e.message ?? 'That item cannot be deleted from here.',
        'not_found' => 'That file no longer exists.',
        _ => e.message ?? 'The file could not be deleted.',
      };
    } catch (_) {
      return 'The file could not be deleted';
    }
  }

  /// True when this entry can be offered a Delete action.
  ///
  /// Deliberately narrow: a local file only. Network-backed entries return
  /// false so the UI hides the option instead of offering something that
  /// would always fail.
  ///
  /// [isAndroid] is a test seam that lets the Android-eligible cases be
  /// verified on a desktop host; production call sites never pass it, so it
  /// defaults to the real platform.
  static bool canDelete(FileEntry e, {bool? isAndroid}) {
    if (e.isDirectory) return false;
    if (!(isAndroid ?? Platform.isAndroid)) return false;
    final p = e.path;
    if (p.startsWith('/')) return true;
    // SAF tree entries arrive with the document URI in `path`.
    if (p.startsWith('content://')) return true;
    return false;
  }

  /// Presents the system folder picker (iOS document picker / Android
  /// ACTION_OPEN_DOCUMENT_TREE). Returns the picked folder, bookmarked for
  /// future sessions, or null if the user cancelled.
  Future<FileEntry?> pickFolder() async {
    final result = await _channel.invokeMapMethod<dynamic, dynamic>('pickFolder');
    if (result == null) return null;
    return FileEntry.fromMap(result);
  }

  /// Same folder picker, but the picked folder is stored as a LIBRARY bookmark
  /// only — it never appears as a file-browser root. Used by "Add folder to
  /// library".
  Future<FileEntry?> pickLibraryFolder() async {
    final result =
        await _channel.invokeMapMethod<dynamic, dynamic>('pickLibraryFolder');
    if (result == null) return null;
    return FileEntry.fromMap(result);
  }

  /// iOS only: presents the system document picker — the Files-app home
  /// (iCloud Drive, On My iPad, Downloads, providers). Returns the picked
  /// video, imported (bookmarked) for future sessions, or null if cancelled.
  Future<FileEntry?> openFilesHome() async {
    final result = await _channel.invokeMapMethod<dynamic, dynamic>('openFilesHome');
    if (result == null) return null;
    return FileEntry.fromMap(result);
  }

  /// Re-grants native access to an imported video's file (iOS security-scoped
  /// bookmarks). No-op on Android.
  Future<bool> resolveImportedPath(String path) async {
    final result = await _channel.invokeMethod<bool>('resolveImportedPath', {
      'path': path,
    });
    return result ?? true;
  }

  /// Re-grants native access to [path] whether it's an imported video or lives
  /// inside a bookmarked folder (iOS re-resolves the folder's security-scoped
  /// bookmark and starts its scope). No-op on Android.
  Future<bool> resolvePath(String path) async {
    final result = await _channel.invokeMethod<bool>('resolvePath', {
      'path': path,
    });
    return result ?? true;
  }

  /// Forgets a bookmarked folder.
  Future<void> removeBookmark(String bookmarkId) async {
    await _channel.invokeMethod<void>('removeBookmark', {
      'bookmarkId': bookmarkId,
    });
  }

  /// Forgets a library-folder bookmark (when a folder is removed from the
  /// library, so its native grant doesn't linger).
  Future<void> removeLibraryBookmark(String bookmarkId) async {
    await _channel.invokeMethod<void>('removeLibraryBookmark', {
      'bookmarkId': bookmarkId,
    });
  }

  /// Presents the system file picker filtered to subtitle files (SRT/ASS/VTT).
  /// Returns the picked file's URI string (content:// on Android, file:// on
  /// iOS) or null if cancelled.
  Future<String?> pickSubtitle() async {
    final result = await _channel.invokeMethod<String>('pickSubtitle');
    return result;
  }

  /// Presents the system file picker for the user's custom MPV config file.
  /// Returns `{uri, name}` (persistable content:// URI) or null if cancelled.
  /// Android-only; iOS has no channel implementation (MPV is Android-only).
  Future<({String uri, String name})?> pickMpvConfig() async {
    final result = await _channel.invokeMethod<Map>('pickMpvConfig');
    if (result == null) return null;
    final uri = result['uri'];
    final name = result['name'];
    if (uri is! String || uri.isEmpty) return null;
    return (uri: uri, name: name is String && name.isNotEmpty ? name : uri);
  }

  /// Reads a text file (content:// / file:// / plain path) up to 1 MiB.
  /// Android-only. Returns null when unreadable.
  Future<String?> readTextFile(String uri) async {
    try {
      return await _channel.invokeMethod<String>('readTextFile', {'uri': uri});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Embedded cover-art bytes for a local video (metadata-only read — safe for
  /// DV/HDR). Returns null when the file has no attached artwork or the source
  /// is remote (http(s) is skipped natively).
  Future<Uint8List?> getThumbnail({String? path, String? uri}) async {
    try {
      return await _channel.invokeMethod<Uint8List>('getThumbnail', {
        'path': path,
        'uri': uri,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // Engine not attached (tests / teardown).
      return null;
    }
  }

}
