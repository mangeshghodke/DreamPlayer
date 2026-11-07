package com.dreamplayer.app

import android.app.Activity
import android.content.Context
import android.os.storage.StorageVolume
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.util.Locale
import java.util.UUID

/// In-app file browser (CX-Explorer style) backed by direct filesystem access.
/// Requires MANAGE_EXTERNAL_STORAGE on Android 11+; folders picked via the
/// system document picker (ACTION_OPEN_DOCUMENT_TREE) stay browsable through
/// persistable URI grants without needing all-files access.
class FileBrowser(private val activity: MainActivity) {

    companion object {
        const val CHANNEL = "dreamplayer/files"
        const val REQ_PICK_FOLDER = 9001
        const val REQ_PICK_SUBTITLE = 9002
        const val REQ_PICK_MPV_CONFIG = 9003

        private const val PREFS = "dreamplayer.folderBookmarks"
        private const val BOOKMARK_PREFIX = "bm."
        private const val LIB_BOOKMARK_PREFIX = "libfolder."
        private const val TREE_PREFIX = "tree:"

        private val VIDEO_EXTENSIONS = setOf(
            "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
            "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
            "strm", "m3u", "m3u8",
        )
    }

    private var pendingFolderResult: MethodChannel.Result? = null
    private var pendingSubtitleResult: MethodChannel.Result? = null
    private var pendingMpvConfigResult: MethodChannel.Result? = null

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /// True while the open picker is a library pick ("Add folder to library"),
    /// so the picked tree is stored under the library bookmark prefix and never
    /// appears as a file-browser root.
    private var pendingFolderIsLibrary = false

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                "openAllFilesAccessSettings" -> {
                    openAllFilesAccessSettings()
                    result.success(null)
                }
                "getStorageRoots" -> try {
                    result.success(storageRoots())
                } catch (e: Exception) {
                    android.util.Log.w("FileBrowser", "getStorageRoots failed", e)
                    result.success(emptyList<Map<String, Any?>>())
                }
                "listDirectory" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "Missing path", null)
                    } else {
                        try {
                            result.success(listDirectory(path))
                        } catch (e: Exception) {
                            android.util.Log.w("FileBrowser", "listDirectory failed for $path", e)
                            result.success(listOf(mapOf("error" to "not_found", "path" to path)))
                        }
                    }
                }
                "pickFolder" -> pickFolder(result)
                "pickLibraryFolder" -> pickLibraryFolder(result)
                "pickSubtitle" -> pickSubtitle(result)
                "pickMpvConfig" -> pickMpvConfig(result)
                "readTextFile" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) {
                        result.error("bad_args", "readTextFile needs uri", null)
                    } else {
                        result.success(readTextFile(uri, 1024 * 1024))
                    }
                }
                "getThumbnail" -> {
                    val path = call.argument<String>("path")
                    val uri = call.argument<String>("uri")
                    Thread {
                        val bytes = embeddedArt(path, uri)
                        mainHandler.post { result.success(bytes) }
                    }.start()
                }
                // Irreversible file deletion, deliberately restricted to
                // LOCAL storage. Network sources (SMB/WebDAV/FTP/UPnP/Jellyfin)
                // are refused: they would each need their own protocol-level
                // delete, and a mis-fired tap on a NAS share is real data loss.
                "deleteLocalFile" -> deleteLocalFile(call, result)
                "copyLocalToDownloads" -> copyLocalToDownloads(call, result)
                "resolveImportedPath" -> result.success(true)
                "resolvePath" -> result.success(true)
                "removeBookmark" -> {
                    val id = call.argument<String>("bookmarkId")
                    if (id != null) removeBookmark(id)
                    result.success(null)
                }
                "removeLibraryBookmark" -> {
                    val id = call.argument<String>("bookmarkId")
                    if (id != null) removeLibraryBookmark(id)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Deletes a local file, permanently.
    ///
    /// Accepts either a plain filesystem path (needs
    /// `MANAGE_EXTERNAL_STORAGE` on Android 11+) or a `content://` SAF URI
    /// (deleted through the persisted tree grant). Refuses anything that is
    /// not a plain local file — a network path, a directory, or a synthetic
    /// `tree:<id>` path — so this can never be used to wipe a share by
    /// accident. Callers are expected to have confirmed with the user first.
    private fun deleteLocalFile(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val uri = call.argument<String>("uri")
        if (path == null && uri == null) {
            result.error("bad_args", "Missing path or uri", null)
            return
        }
        // Synthetic SAF paths are addressed by uri, never by path.
        if (path != null && path.startsWith("tree:")) {
            result.error("unsupported", "Delete this folder from the file browser", null)
            return
        }
        if (path != null && (path.startsWith("smb:") || path.startsWith("ftp:") ||
                path.startsWith("sftp:") || path.startsWith("http") ||
                path.startsWith("jellyfin:") || path.startsWith("upnp:"))) {
            result.error(
                "unsupported",
                "Only local files can be deleted. Remove it from the network share instead.",
                null
            )
            return
        }
        if (!hasAllFilesAccess() && uri == null) {
            result.error(
                "no_permission",
                "All Files Access is required to delete a local file",
                null
            )
            return
        }

        // A non-content:// uri cannot be deleted safely and the path branch
        // below needs a non-null path; reject rather than risk a null deref.
        if (path == null && (uri == null || !uri.startsWith("content://"))) {
            result.error("unsupported", "That item cannot be deleted from here", null)
            return
        }

        val deleted = if (uri != null && uri.startsWith("content://")) {
            val resolver = activity.contentResolver
            try {
                resolver.delete(Uri.parse(uri), null, null) > 0
            } catch (e: Exception) {
                result.error("delete_failed", e.message ?: "Could not delete the file", null)
                return
            }
        } else {
            val f = File(path)
            // Directories are deleted RECURSIVELY (issue #48 follow-up): a
            // user who selects a folder to delete means the whole tree. The
            // Dart side confirms before calling, and nothing outside the app's
            // own storage roots is ever accepted below.
            if (f.isDirectory) {
                if (!isDeletableTarget(f)) {
                    result.error("no_permission", "No permission to delete this folder", null)
                    return
                }
                if (!deleteRecursively(f)) {
                    result.error("delete_failed", "Could not delete the folder", null)
                    return
                }
                result.success(true)
                return
            }
            if (!Environment.isExternalStorageManager() &&
                !f.absolutePath.startsWith(activity.filesDir.parent ?: "")
            ) {
                result.error("no_permission", "No permission to delete this file", null)
                return
            }
            if (!f.exists()) {
                result.error("not_found", "That file no longer exists", null)
                return
            }
            if (!f.delete()) {
                result.error("delete_failed", "Could not delete the file", null)
                return
            }
            true
        }
        result.success(deleted)
    }

    /// Copies a local file or folder into the app's download directory.
    ///
    /// The browser's "Download to device" action: the picked file is copied
    /// into `<Downloads>/DreamPlayer/`, which is the same place the network
    /// downloader writes, so downloaded files all land in one folder.
    /// Conflicts never overwrite — a suffix is appended, because silently
    /// clobbering an existing file is worse than a duplicated name.
    private fun copyLocalToDownloads(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.error("bad_args", "Missing path", null)
            return
        }
        if (path.startsWith("tree:") ||
            path.startsWith("smb:") || path.startsWith("ftp:") || path.startsWith("sftp:") ||
            path.startsWith("http") || path.startsWith("jellyfin:") || path.startsWith("upnp:")
        ) {
            result.error("unsupported", "Only local files can be copied", null)
            return
        }
        if (!hasAllFilesAccess()) {
            result.error(
                "no_permission",
                "All Files Access is required to copy files",
                null
            )
            return
        }
        val source = File(path)
        if (!source.exists()) {
            result.error("not_found", "That file no longer exists", null)
            return
        }
        val base = try {
            val dir = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS
            )
            File(dir, "DreamPlayer")
        } catch (e: Exception) {
            result.error("copy_failed", e.message ?: "Downloads folder unavailable", null)
            return
        }
        if (!base.exists() && !base.mkdirs()) {
            result.error("copy_failed", "Could not create the DreamPlayer folder", null)
            return
        }
        try {
            val destination = uniqueDestination(base, source.name)
            if (source.isDirectory) {
                copyTree(source, destination)
            } else {
                source.copyTo(destination, overwrite = false)
            }
            result.success(destination.absolutePath)
        } catch (e: Exception) {
            result.error("copy_failed", e.message ?: "Could not copy the file", null)
        }
    }

    /// First free `name` under [dir], appending " (2)", " (3)"… on collision.
    private fun uniqueDestination(dir: File, name: String): File {
        var candidate = File(dir, name)
        if (!candidate.exists()) return candidate
        val base = name.substringBeforeLast('.', name)
        val ext = name.substringAfterLast('.', "")
        var index = 2
        while (candidate.exists() && index < 1000) {
            val next = if (ext.isEmpty()) "$base ($index)" else "$base ($index).$ext"
            candidate = File(dir, next)
            index++
        }
        return candidate
    }

    private fun copyTree(source: File, destination: File) {
        if (source.isDirectory) {
            if (!destination.exists()) destination.mkdirs()
            source.listFiles()?.forEach { child ->
                copyTree(child, File(destination, child.name))
            }
        } else {
            source.copyTo(destination, overwrite = true)
        }
    }

    /// True when [file] lives under a real external-storage root.
    ///
    /// Guards recursive deletion: a bug in the UI must not be able to walk up
    /// from a bad path and remove something outside storage.
    private fun isDeletableTarget(file: File): Boolean {
        val path = try {
            file.canonicalPath
        } catch (e: Exception) {
            file.absolutePath
        }
        return listOf(
            "/storage/",
            "/sdcard/",
            Environment.getExternalStorageDirectory()?.absolutePath ?: ""
        ).any { it.isNotEmpty() && path.startsWith(it) }
    }

    private fun deleteRecursively(file: File): Boolean {
        if (file.isDirectory) {
            file.listFiles()?.forEach { child ->
                if (!deleteRecursively(child)) return false
            }
        }
        return file.delete()
    }

    private fun hasAllFilesAccess(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()

    /// Embedded cover-art bytes for a local file or content URI. This is a
    /// METADATA-ONLY read — `MediaMetadataRetriever.getEmbeddedPicture()` never
    /// touches the video decoder, so DV/HDR content is safe (unlike frame
    /// extraction, which returns black frames on Qualcomm for HDR). http(s)
    /// sources are skipped: network artwork belongs to TMDB posters instead.
    private fun embeddedArt(path: String?, uri: String?): ByteArray? {
        val isLocalPath = !path.isNullOrEmpty() && !path.startsWith("http")
        val localUri = uri?.takeIf { it.startsWith("content:") || it.startsWith("file:") }
        if (!isLocalPath && localUri == null) return null
        val retriever = android.media.MediaMetadataRetriever()
        return try {
            if (localUri != null) retriever.setDataSource(activity, Uri.parse(localUri))
            else retriever.setDataSource(path)
            retriever.embeddedPicture
        } catch (_: Exception) {
            null
        } finally {
            try { retriever.release() } catch (_: Exception) {}
        }
    }

    private fun openAllFilesAccessSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val intent = Intent(
            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
            Uri.parse("package:${activity.packageName}"),
        )
        try {
            activity.startActivity(intent)
        } catch (_: Exception) {
            activity.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }

    // MARK: - Roots

    /// Storage roots shown at the top level: internal, every mounted removable
    /// volume (USB stick, SD card), then bookmarks.
    ///
    /// Issue #48: this used to list `/storage` and skip anything named `usb*`.
    /// That filter was aimed at the legacy `/storage/usb` FUSE mount, but it is
    /// also exactly the name a USB volume had on many devices — so plugging in
    /// a drive showed nothing at all, on a TV especially. The modern mount
    /// point is `/storage/<VOLUME_UUID>` with no `usb` in the name, and the
    /// `StorageManager` is the API that actually reports it.
    ///
    /// Both are used: `StorageManager` gives the real volumes WITH their
    /// display names, and the `/storage` scan is kept as a fallback for devices
    /// where the volume list is empty or unreadable. Duplicates are collapsed,
    /// so a volume seen by both appears once.
    private fun storageRoots(): List<Map<String, Any?>> {
        val roots = mutableListOf<Map<String, Any?>>()
        val seen = mutableSetOf<String>()

        Environment.getExternalStorageDirectory()?.let { internal ->
            roots.add(rootEntry(internal.absolutePath, "Internal storage"))
            seen.add(internal.absolutePath)
        }

        // Primary: volumes the platform actually reports.
        runCatching {
            val storageManager =
                activity.getSystemService(Context.STORAGE_SERVICE) as? StorageManager
            storageManager?.storageVolumes?.forEach { volume ->
                val dir = volumeDirectory(volume) ?: return@forEach
                if (!dir.isDirectory || !seen.add(dir.absolutePath)) return@forEach
                roots.add(rootEntry(dir.absolutePath, volumeLabel(volume)))
            }
        }.onFailure {
            android.util.Log.w("FileBrowser", "storageVolumes unavailable", it)
        }

        // Fallback: /storage scan. Internal storage is named `emulated`; every
        // other real mount point is a volume. `self` and the legacy `usb`
        // directory are NOT volumes and are skipped - note that `usb` is also
        // skipped here only because such a path is the old FUSE mount, whereas
        // a real USB drive now mounts at /storage/<UUID> and is already
        // covered by the StorageManager pass above.
        File("/storage").takeIf { it.isDirectory }?.listFiles()?.forEach { vol ->
            val name = vol.name
            if (!vol.isDirectory || name == "emulated" || name == "self" ||
                name.startsWith("usb") || name == "container"
            ) {
                return@forEach
            }
            if (!seen.add(vol.absolutePath)) return@forEach
            roots.add(rootEntry(vol.absolutePath, "SD card ($name)"))
        }

        roots.addAll(bookmarkEntries())
        return roots
    }

    /// Filesystem directory for a volume, or null when it is not mounted for us.
    ///
    /// Only `getDirectory()` is used, and only on API 30+. The deprecated
    /// `getPath()` was removed in API 31 and does not compile against this
    /// project's compileSdk 37 at all, so the older-device fallback has to
    /// come from the `/storage` scan below rather than from a second API here.
    private fun volumeDirectory(volume: StorageVolume): File? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        return try {
            // Throws when the volume is not mounted for this app.
            volume.getDirectory()
        } catch (e: Exception) {
            android.util.Log.w("FileBrowser", "volume directory unavailable", e)
            null
        }
    }

    /// Display name for a volume: "USB drive", the SD-card name, or just the
    /// kind when the platform gives no description.
    private fun volumeLabel(volume: StorageVolume): String {
        val removable = try {
            volume.isRemovable
        } catch (e: Exception) {
            false
        }
        val kind = if (removable) "USB drive" else "SD card"
        val description = try {
            @Suppress("DEPRECATION")
            volume.getDescription(activity)
        } catch (e: Exception) {
            null
        }?.trim().orEmpty()
        return if (description.isEmpty()) kind else "$kind ($description)"
    }

    private fun rootEntry(path: String, name: String): Map<String, Any?> = mapOf(
        "name" to name,
        "path" to path,
        "isDirectory" to true,
        "size" to 0L,
    )

    // MARK: - Listing

    private fun listDirectory(path: String): List<Map<String, Any?>> =
        if (path.startsWith(TREE_PREFIX)) listTreeDirectory(path)
        else listFileDirectory(path)

    private fun listFileDirectory(path: String): List<Map<String, Any?>> {
        val dir = File(path)
        if (!dir.exists() || !dir.isDirectory) {
            return listOf(mapOf("error" to "not_found", "path" to path))
        }
        val entries = dir.listFiles() ?: return emptyList()
        val dirs = mutableListOf<Map<String, Any?>>()
        val files = mutableListOf<Map<String, Any?>>()
        for (f in entries) {
            val name = f.name
            if (name.startsWith(".")) continue
            if (f.isDirectory) {
                dirs.add(entry(f, isDirectory = true))
            } else if (isVideo(name)) {
                files.add(entry(f, isDirectory = false))
            }
        }
        dirs.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
        files.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
        return dirs + files
    }

    /// Lists a bookmarked tree (`tree:<id>` or `tree:<id>/<relative/path>`).
    /// Directory entries carry the synthetic `tree:` path for navigation; video
    /// files carry their `content://` document URI so playback works through the
    /// player's `uri` path.
    private fun listTreeDirectory(path: String): List<Map<String, Any?>> {
        android.util.Log.d("FileBrowser", "listTreeDirectory path=$path")
        val (id, relative) = parseTreePath(path)
        val treeUri = treeUriFor(id)
        android.util.Log.d("FileBrowser", "listTreeDirectory id=$id relative=$relative treeUri=$treeUri")
        if (treeUri == null) {
            android.util.Log.e("FileBrowser", "listTreeDirectory: treeUriFor($id) returned null")
            return listOf(mapOf("error" to "not_found", "path" to path))
        }

        // For local-storage trees (primary:..., secondary:...), resolve the
        // actual file-system path and list directly — this avoids SAF grant
        // issues where DocumentFile.listFiles() returns empty after a
        // flutter install / APK reinstall.
        val localPath = resolveLocalPath(treeUri, relative)
        android.util.Log.d("FileBrowser", "listTreeDirectory: resolveLocalPath=$localPath")
        if (localPath != null) {
            android.util.Log.d("FileBrowser", "listTreeDirectory: listing local path=$localPath")
            val result = listFileDirectory(localPath)
            android.util.Log.d("FileBrowser", "listTreeDirectory: local result size=${result.size}")
            return result
        }

        // Fallback: SAF DocumentFile path (for non-local providers). A tree
        // whose backing volume was removed/unmounted or whose grant was
        // revoked since bookmarking throws from findFile/isDirectory/
        // listFiles/child.name with no warning — caught here so the caller
        // gets the same structured not_found response as every other
        // missing-folder case instead of an unhandled platform exception.
        try {
            try {
                val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                activity.contentResolver.takePersistableUriPermission(treeUri, flags)
            } catch (_: Exception) { /* grant may fail; best-effort */ }
            var doc = DocumentFile.fromTreeUri(activity, treeUri)
                ?: return listOf(mapOf("error" to "not_found", "path" to path))
            if (relative.isNotEmpty()) {
                for (segment in relative.split('/')) {
                    if (segment.isEmpty()) continue
                    doc = doc.findFile(segment)
                        ?: return listOf(mapOf("error" to "not_found", "path" to path))
                }
            }
            if (!doc.isDirectory) return listOf(mapOf("error" to "not_found", "path" to path))
            val base = if (relative.isEmpty()) treePath(id) else "${treePath(id)}/$relative"
            val dirs = mutableListOf<Map<String, Any?>>()
            val files = mutableListOf<Map<String, Any?>>()
            for (child in doc.listFiles()) {
                val name = child.name ?: continue
                if (name.startsWith(".")) continue
                if (child.isDirectory) {
                    dirs.add(
                        mapOf(
                            "name" to name,
                            "path" to "$base/$name",
                            "isDirectory" to true,
                            "size" to 0L,
                        ),
                    )
                } else if (isVideo(name)) {
                    files.add(
                        mapOf(
                            "name" to name,
                            "path" to child.uri.toString(),
                            "isDirectory" to false,
                            "size" to child.length(),
                        ),
                    )
                }
            }
            dirs.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
            files.sortBy { it["name"].toString().lowercase(Locale.ROOT) }
            return dirs + files
        } catch (e: Exception) {
            android.util.Log.w("FileBrowser", "listTreeDirectory: SAF listing failed for $path", e)
            return listOf(mapOf("error" to "not_found", "path" to path))
        }
    }

    /// Attempts to resolve a tree URI to an actual local file-system path.
    /// Works for `primary:` (internal) and `secondary:` (SD card) volumes.
    /// Returns null for non-local providers (USB, cloud, etc.).
    private fun resolveLocalPath(treeUri: android.net.Uri, relative: String): String? {
        val treeId = try {
            android.provider.DocumentsContract.getTreeDocumentId(treeUri)
        } catch (e: Exception) {
            android.util.Log.e("FileBrowser", "resolveLocalPath: getTreeDocumentId failed: $e")
            return null
        }
        if (treeId == null) {
            android.util.Log.e("FileBrowser", "resolveLocalPath: treeId is null")
            return null
        }
        val prefix = treeId.substringBefore(':', "")
        val rest = treeId.substringAfter(':', "")
        val basePath = when (prefix) {
            "primary" -> "/storage/emulated/0/$rest"
            "secondary" -> "/storage/sdcard1/$rest"
            else -> {
                android.util.Log.d("FileBrowser", "resolveLocalPath: non-local prefix=$prefix, treeId=$treeId")
                return null
            }
        }
        val dir = if (relative.isEmpty()) File(basePath) else File(basePath, relative)
        android.util.Log.d("FileBrowser", "resolveLocalPath: treeId=$treeId prefix=$prefix rest=$rest basePath=$basePath relative=$relative dir=${dir.absolutePath} exists=${dir.exists()} isDir=${dir.isDirectory}")
        if (dir.exists() && dir.isDirectory) {
            val children = dir.listFiles()
            android.util.Log.d("FileBrowser", "resolveLocalPath: children count=${children?.size}")
            children?.take(5)?.forEach { android.util.Log.d("FileBrowser", "resolveLocalPath: child=${it.name} isDir=${it.isDirectory}") }
        }
        return if (dir.exists() && dir.isDirectory) dir.absolutePath else null
    }

    private fun isVideo(name: String): Boolean {
        val dot = name.lastIndexOf('.')
        if (dot < 0 || dot == name.length - 1) return false
        return name.substring(dot + 1).lowercase(Locale.ROOT) in VIDEO_EXTENSIONS
    }

    private fun entry(f: File, isDirectory: Boolean): Map<String, Any?> = mapOf(
        "name" to f.name,
        "path" to f.absolutePath,
        "isDirectory" to isDirectory,
        "size" to if (isDirectory) 0L else f.length(),
    )

    // MARK: - Bookmarks

    private fun bookmarks(): SharedPreferences =
        activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun keyFor(id: String) = BOOKMARK_PREFIX + id

    private fun keyForLib(id: String) = LIB_BOOKMARK_PREFIX + id

    private fun treePath(id: String) = TREE_PREFIX + id

    private fun parseTreePath(path: String): Pair<String, String> {
        val rest = path.removePrefix(TREE_PREFIX)
        val slash = rest.indexOf('/')
        return if (slash < 0) rest to "" else rest.substring(0, slash) to rest.substring(slash + 1)
    }

    /// Resolves a tree URI from either bookmark store (file-browser or library),
    /// so `listDirectory` can open both a file-browser root and a library folder.
    private fun treeUriFor(id: String): Uri? {
        val prefs = bookmarks()
        val stored = prefs.getString(keyFor(id), null)
            ?: prefs.getString(keyForLib(id), null)
            ?: return null
        return try {
            Uri.parse(stored)
        } catch (_: Exception) {
            null
        }
    }

    private fun bookmarkEntries(): List<Map<String, Any?>> {
        val prefs = bookmarks()
        return prefs.all.keys
            .filter { it.startsWith(BOOKMARK_PREFIX) }
            .mapNotNull { key ->
                // A single stale/revoked SAF grant (SD card removed, access
                // revoked in system Settings, a grant that didn't survive a
                // reinstall) must not take down the WHOLE root list — without
                // this, one bad bookmark hides internal storage and every
                // other healthy bookmark too.
                try {
                    val id = key.removePrefix(BOOKMARK_PREFIX)
                    val uri = treeUriFor(id) ?: return@mapNotNull null
                    val doc = DocumentFile.fromTreeUri(activity, uri) ?: return@mapNotNull null
                    mapOf(
                        "name" to treeDisplayName(uri, doc),
                        "path" to treePath(id),
                        "isDirectory" to true,
                        "size" to 0L,
                        "bookmarkId" to id,
                    )
                } catch (e: Exception) {
                    android.util.Log.w("FileBrowser", "bookmarkEntries: skipping inaccessible bookmark $key", e)
                    null
                }
            }
    }

    private fun treeDisplayName(treeUri: Uri, doc: DocumentFile?): String {
        doc?.name?.let { return it }
        val treeId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (_: Exception) {
            null
        }
        if (!treeId.isNullOrEmpty()) {
            val name = treeId.substringAfterLast(':')
            if (name.isNotEmpty()) return name
        }
        return treeUri.lastPathSegment ?: "Folder"
    }

    private fun removeBookmark(id: String) {
        val prefs = bookmarks()
        val stored = prefs.getString(keyFor(id), null)
        prefs.edit().remove(keyFor(id)).apply()
        if (stored != null) {
            try {
                activity.contentResolver.releasePersistableUriPermission(
                    Uri.parse(stored),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (_: Exception) {
            }
        }
    }

    private fun removeLibraryBookmark(id: String) {
        val prefs = bookmarks()
        val stored = prefs.getString(keyForLib(id), null)
        prefs.edit().remove(keyForLib(id)).apply()
        if (stored != null) {
            try {
                activity.contentResolver.releasePersistableUriPermission(
                    Uri.parse(stored),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (_: Exception) {
            }
        }
    }

    // MARK: - Folder picker

    /// Launches the system folder picker (ACTION_OPEN_DOCUMENT_TREE). The result
    /// arrives in [MainActivity.onActivityResult] and is forwarded to
    /// [onFolderPicked].
    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingFolderResult != null) {
            result.error("busy", "A folder picker is already open", null)
            return
        }
        pendingFolderIsLibrary = false
        startFolderPicker(result)
    }

    /// Same picker, but the picked tree is stored as a LIBRARY bookmark — it
    /// never shows up as a file-browser root.
    private fun pickLibraryFolder(result: MethodChannel.Result) {
        if (pendingFolderResult != null) {
            result.error("busy", "A folder picker is already open", null)
            return
        }
        pendingFolderIsLibrary = true
        startFolderPicker(result)
    }

    private fun startFolderPicker(result: MethodChannel.Result) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        pendingFolderResult = result
        try {
            activity.startActivityForResult(intent, REQ_PICK_FOLDER)
        } catch (_: Exception) {
            pendingFolderResult = null
            result.error("no_picker", "No folder picker available", null)
        }
    }

    // MARK: - Subtitle picker

    private fun pickSubtitle(result: MethodChannel.Result) {
        if (pendingSubtitleResult != null) {
            result.error("busy", "A subtitle picker is already open", null)
            return
        }
        val baseIntent = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val pm = activity.packageManager
        val candidates = try {
            pm.queryIntentActivities(baseIntent, 0)
        } catch (_: Exception) { emptyList() }
        val openDoc = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        val extraIntents = candidates.mapNotNull { info ->
            val pkg = info.activityInfo.packageName
            val cls = info.activityInfo.name
            if (pkg == "com.google.android.documentsui" ||
                pkg == "com.android.documentsui") return@mapNotNull null
            Intent(baseIntent).apply { setClassName(pkg, cls) }
        }.toMutableList()
        extraIntents.add(openDoc)
        android.util.Log.d("FileBrowser", "pickSubtitle candidates=${candidates.map { it.activityInfo.packageName }} extras=${extraIntents.map { it.`package` }}")
        val chooser = Intent.createChooser(baseIntent, "Select subtitle file").apply {
            if (extraIntents.isNotEmpty()) {
                putExtra(Intent.EXTRA_INITIAL_INTENTS, extraIntents.toTypedArray())
            }
        }
        pendingSubtitleResult = result
        try {
            activity.startActivityForResult(chooser, REQ_PICK_SUBTITLE)
        } catch (_: Exception) {
            pendingSubtitleResult = null
            result.error("no_picker", "No file picker available", null)
        }
    }

    fun onSubtitlePicked(resultCode: Int, data: Intent?) {
        val result = pendingSubtitleResult ?: return
        pendingSubtitleResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        val uri = data.data!!
        // Persist permission if possible; CX's SMB provider only grants
        // temporary permission, so also copy to a cache file immediately
        // while the grant is still valid — otherwise ExoPlayer reads it
        // later and the provider may be dead (CX task was killed).
        var outUri = uri.toString()
        try {
            activity.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (_: Exception) {
        }
        // For content:// from file managers (especially CX SMB), copy to
        // cache now so playback doesn't depend on the provider staying alive.
        if (uri.scheme == "content") {
            try {
                activity.contentResolver.openInputStream(uri)?.use { input ->
                    val ext = uri.lastPathSegment?.substringAfterLast('.', "srt") ?: "srt"
                    val tmp = java.io.File(activity.cacheDir, "picked_sub_${System.currentTimeMillis()}.$ext")
                    tmp.outputStream().use { out -> input.copyTo(out) }
                    if (tmp.exists() && tmp.length() > 0) {
                        outUri = android.net.Uri.fromFile(tmp).toString()
                        android.util.Log.d("FileBrowser", "subtitle copied to cache: $outUri (${tmp.length()} bytes)")
                    }
                }
            } catch (e: Exception) {
                android.util.Log.w("FileBrowser", "subtitle cache copy failed, using original uri: $e")
            }
        }
        result.success(outUri)
    }

    // MARK: - MPV config picker (user's own mpv.conf)

    /// Picks a config file for the MPV engine. Unlike [pickSubtitle] the URI is
    /// kept as-is (persistable permission taken): the user edits their own
    /// file between sessions, so it must NOT be copied to cache.
    private fun pickMpvConfig(result: MethodChannel.Result) {
        if (pendingMpvConfigResult != null) {
            result.error("busy", "A file picker is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        pendingMpvConfigResult = result
        try {
            activity.startActivityForResult(intent, REQ_PICK_MPV_CONFIG)
        } catch (_: Exception) {
            pendingMpvConfigResult = null
            result.error("no_picker", "No file picker available", null)
        }
    }

    fun onMpvConfigPicked(resultCode: Int, data: Intent?) {
        val result = pendingMpvConfigResult ?: return
        pendingMpvConfigResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        val uri = data.data!!
        try {
            activity.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (_: Exception) {
        }
        var name = uri.lastPathSegment?.substringAfterLast('/') ?: "mpv.conf"
        try {
            activity.contentResolver.query(
                uri,
                arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)?.takeIf { it.isNotBlank() }?.let { name = it }
                }
            }
        } catch (_: Exception) {
        }
        result.success(mapOf("uri" to uri.toString(), "name" to name))
    }

    /// Reads up to [maxBytes] of a text file from a content:// / file:// URI or
    /// plain path. Returns null when unreadable.
    private fun readTextFile(uriString: String, maxBytes: Int): String? {
        try {
            val uri = android.net.Uri.parse(uriString)
            val stream = when (uri.scheme) {
                null, "file" -> java.io.File(uri.path ?: uriString).takeIf { it.isFile }?.inputStream()
                else -> activity.contentResolver.openInputStream(uri)
            } ?: return null
            return stream.use { input ->
                val buf = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(8192)
                var total = 0
                while (true) {
                    val n = input.read(chunk)
                    if (n < 0) break
                    if (total + n > maxBytes) {
                        buf.write(chunk, 0, maxBytes - total)
                        break
                    }
                    buf.write(chunk, 0, n)
                    total += n
                }
                buf.toString("UTF-8")
            }
        } catch (e: Exception) {
            android.util.Log.w("FileBrowser", "readTextFile failed for $uriString: $e")
            return null
        }
    }

    fun onFolderPicked(resultCode: Int, data: Intent?) {
        val result = pendingFolderResult ?: return
        pendingFolderResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null) // cancelled
            return
        }
        val treeUri = data.data!!
        val grantSucceeded = try {
            activity.contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
            true
        } catch (e: Exception) {
            // Android caps persistable grants per app (~128) and some
            // providers reject GRANT_PERSISTABLE outright. Bookmarking
            // anyway would save a folder that silently fails to list on the
            // next process restart with no diagnostic for the user — surface
            // the failure instead of pretending it succeeded.
            android.util.Log.w("FileBrowser", "takePersistableUriPermission failed for $treeUri, not bookmarking", e)
            false
        }
        if (!grantSucceeded) {
            result.error("grant_failed", "Could not get lasting access to the selected folder", null)
            return
        }
        val id = UUID.randomUUID().toString()
        if (pendingFolderIsLibrary) {
            bookmarks().edit().putString(keyForLib(id), treeUri.toString()).apply()
        } else {
            bookmarks().edit().putString(keyFor(id), treeUri.toString()).apply()
        }
        val doc = DocumentFile.fromTreeUri(activity, treeUri)
        result.success(
            mapOf(
                "name" to treeDisplayName(treeUri, doc),
                "path" to treePath(id),
                "isDirectory" to true,
                "size" to 0L,
                "bookmarkId" to id,
            ),
        )
    }
}
