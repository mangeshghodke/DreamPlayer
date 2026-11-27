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
  /// document picker - the real Files-app home - instead of listing a path.
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
      // failure - a silent mismatch that only showed up as a red snackbar.
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
  /// unreadable folder was indistinguishable from an empty one - and adding
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
  /// URI. Network sources are refused natively - deleting from a NAS share
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
  /// only - it never appears as a file-browser root. Used by "Add folder to
  /// library".
  Future<FileEntry?> pickLibraryFolder() async {
    final result =
        await _channel.invokeMapMethod<dynamic, dynamic>('pickLibraryFolder');
    if (result == null) return null;
    return FileEntry.fromMap(result);
  }

  /// iOS only: presents the system document picker - the Files-app home
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

  /// Folder picker for "send a whole folder to computer": opens the system
/// folder picker, walks every file inside (recursively, capped 2000), and
/// returns them as {uri, name, size} maps. Names carry the relative path so
/// subfolders keep unique names. Empty list if cancelled.
Future<List<Map<String, dynamic>>> pickFolderContents() async {
  try {
    final result = await _channel.invokeListMethod<dynamic>('pickFolderContents');
    if (result == null) return const [];
    return result
        .whereType<Map>()
        .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  } on PlatformException {
    return const [];
  } on MissingPluginException {
    return const [];
  }
}

/// Multi-select FILE picker for "send files to computer". Returns a list of
  /// `{uri, name, size}` maps (content:// URIs on Android, file:// on iOS).
  /// NO file copying happens here - the URIs are handed to the WiFi upload
  /// server, which streams them directly when a PC downloads. Empty list if
  /// the user cancelled.
  Future<List<Map<String, dynamic>>> pickFiles() async {
    try {
      final result = await _channel.invokeListMethod<dynamic>('pickFiles');
      if (result == null) return const [];
      return result
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// iOS only: opens the system PHOTOS picker (images) and returns the
  /// picked photos as `{uri, name, size}` maps named `Photos/<file>`.
  /// The native side copies each photo to a stable temp file first -
  /// PHPicker's file-representation URLs are only valid inside the picker
  /// callback, and the upload server streams the URIs later, when the PC
  /// downloads. Empty list on Android (method not implemented) or cancel.
  Future<List<Map<String, dynamic>>> pickPhotos() async {
    try {
      final result = await _channel.invokeListMethod<dynamic>('pickPhotos');
      if (result == null) return const [];
      return result
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// iOS only: progress events `{done, total}` emitted by the photos picker
  /// as each picked item is copied to a stable temp file. Lets the transfer
  /// screen show a determinate bar under the Send buttons while the copy of
  /// large videos runs (otherwise the buttons sit greyed out with no
  /// feedback and the user force-closes the app). Empty stream on Android.
  Stream<Map<String, int>> pickProgressStream() {
    if (!Platform.isIOS) return const Stream.empty();
    return const EventChannel('dreamplayer/pick_progress')
        .receiveBroadcastStream()
        .cast<Map>()
        .map((m) => m.map((k, v) => MapEntry(
              k.toString(),
              (v is num) ? v.toInt() : 0,
            )));
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

  /// Presents the system file picker for a font file (`.ttf` / `.otf` / `.ttc`
  /// / `.woff`), offered from anywhere the user stores fonts (SD card, Files,
  /// iCloud Drive, Downloads). Returns `{uri, name}` or null if cancelled.
  /// Implemented on both platforms (Android SAF `ACTION_OPEN_DOCUMENT`,
  /// iOS `UIDocumentPickerViewController` with font UTIs).
  Future<({String uri, String name})?> pickFontFile() async {
    try {
      final result = await _channel.invokeMethod<Map>('pickFontFile');
      if (result == null) return null;
      final uri = result['uri'];
      final name = result['name'];
      if (uri is! String || uri.isEmpty) return null;
      return (uri: uri, name: name is String && name.isNotEmpty ? name : uri);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Copies the picked font at [uri] (content:// / file:// / plain path) to
  /// [destPath] inside the app's own storage, so the subtitle renderers can
  /// read it without a live provider grant (CX/SMB providers die with their
  /// host app; iCloud files may not be resident). Returns true on success.
  Future<bool> copyFontFile(String uri, String destPath) async {
    try {
      final ok = await _channel.invokeMethod<bool>('copyFontFile', {
        'uri': uri,
        'destPath': destPath,
      });
      return ok == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
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

  /// Embedded cover-art bytes for a media file, any source (metadata-only read
  /// - safe for DV/HDR). The native side reads local/content files directly,
  /// `smb://` via the loopback proxy (Android) or a libsmb2 head+tail temp file
  /// (iOS), and `http(s)://` via the URL with [headers]. Returns null when the
  /// file has no attached artwork or the source cannot be read.
  Future<Uint8List?> getThumbnail({
    String? path,
    String? uri,
    Map<String, String>? headers,
    bool allowSelfSigned = false,
    String? resumeKey,
  }) async {
    try {
      return await _channel.invokeMethod<Uint8List>('getThumbnail', {
        'path': path,
        'uri': uri,
        'headers': headers,
        'allowSelfSigned': allowSelfSigned,
        'resumeKey': resumeKey,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // Engine not attached (tests / teardown).
      return null;
    }
  }

  /// Embedded cover-art bytes for a LOCAL temp file (Dart-side head+tail
  /// download of a remote source the native side cannot read, e.g. ftp:// or
  /// self-signed https). Same metadata-only read as [getThumbnail].
  Future<Uint8List?> getThumbnailFile(String filePath) async {
    try {
      return await _channel.invokeMethod<Uint8List>('getThumbnailFile', {
        'filePath': filePath,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

}
