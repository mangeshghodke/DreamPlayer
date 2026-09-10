package com.dreamplayer.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodChannel
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

        private const val PREFS = "dreamplayer.folderBookmarks"
        private const val BOOKMARK_PREFIX = "bm."
        private const val LIB_BOOKMARK_PREFIX = "libfolder."
        private const val TREE_PREFIX = "tree:"

        private val VIDEO_EXTENSIONS = setOf(
            "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
            "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
        )
    }

    private var pendingFolderResult: MethodChannel.Result? = null
    private var pendingSubtitleResult: MethodChannel.Result? = null

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
                "getStorageRoots" -> result.success(storageRoots())
                "listDirectory" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "Missing path", null)
                    } else {
                        result.success(listDirectory(path))
                    }
                }
                "pickFolder" -> pickFolder(result)
                "pickLibraryFolder" -> pickLibraryFolder(result)
                "pickSubtitle" -> pickSubtitle(result)
                "getThumbnail" -> {
                    val path = call.argument<String>("path")
                    val uri = call.argument<String>("uri")
                    Thread {
                        val bytes = embeddedArt(path, uri)
                        mainHandler.post { result.success(bytes) }
                    }.start()
                }
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

    private fun storageRoots(): List<Map<String, Any?>> {
        val roots = mutableListOf<Map<String, Any?>>()
        Environment.getExternalStorageDirectory()?.let { internal ->
            roots.add(rootEntry(internal.absolutePath, "Internal storage"))
        }
        File("/storage").takeIf { it.isDirectory }?.listFiles()?.forEach { vol ->
            if (vol.isDirectory && vol.name != "emulated" && vol.name != "self" &&
                !vol.name.startsWith("usb")
            ) {
                roots.add(rootEntry(vol.absolutePath, "SD card (${vol.name})"))
            }
        }
        roots.addAll(bookmarkEntries())
        return roots
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
        val (id, relative) = parseTreePath(path)
        val treeUri = treeUriFor(id)
            ?: return listOf(mapOf("error" to "not_found", "path" to path))
        // Re-grant bookmark permission — Android revokes SAF grants
        // (e.g. after every flutter install / APK reinstall).
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

    fun onFolderPicked(resultCode: Int, data: Intent?) {
        val result = pendingFolderResult ?: return
        pendingFolderResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null) // cancelled
            return
        }
        val treeUri = data.data!!
        try {
            activity.contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (_: Exception) {
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
