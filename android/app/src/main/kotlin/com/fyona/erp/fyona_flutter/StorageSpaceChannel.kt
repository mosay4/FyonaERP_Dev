package com.fyona.erp.fyona_flutter

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Storage helpers for large backups.
 *
 * "freeBytes" {path}: space the app may still write on the volume of path.
 * "saveFileToDownloads" {path, fileName, mimeType}: copies a file to
 * Downloads/FYONA ERP in 1 MiB blocks (never loads it into memory), so a
 * backup of any size can be kept on the phone. Android 9 and older need the
 * storage permission the app already requests for its other saves.
 * Both run on a background thread.
 */
object StorageSpaceChannel {
    private const val NAME = "com.fyona.erp/storage_space"
    private const val FOLDER = "FYONA ERP"

    fun register(context: Context, messenger: BinaryMessenger) {
        val main = Handler(Looper.getMainLooper())
        val app = context.applicationContext
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "freeBytes" -> {
                    val path = call.argument<String>("path") ?: ""
                    Thread {
                        val free = try { StatFs(path).availableBytes } catch (_: Throwable) { -1L }
                        main.post { result.success(if (free < 0) null else free) }
                    }.start()
                }
                "saveFileToDownloads" -> {
                    val path = call.argument<String>("path") ?: ""
                    val name = (call.argument<String>("fileName") ?: "").replace('/', '_')
                    val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
                    Thread {
                        val ok = try { copyToDownloads(app, File(path), name, mime) } catch (_: Throwable) { false }
                        main.post { result.success(ok) }
                    }.start()
                }
                "listFyonaFiles" -> {
                    // FYONA backup files of [extensions] in Download/FYONA ERP: this
                    // install's own files (MediaStore), the folder itself (old
                    // Android / readable), and a folder the user granted (tree).
                    val exts = (call.argument<List<String>>("extensions") ?: emptyList()).map { it.lowercase() }
                    val tree = call.argument<String>("treeUri")
                    Thread {
                        val files = try { listFiles(app, exts, tree) } catch (_: Throwable) { emptyList() }
                        main.post { result.success(files) }
                    }.start()
                }
                "copyUriToFile" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    val path = call.argument<String>("path") ?: ""
                    Thread {
                        val ok = try { copyUri(app, uri, File(path)) } catch (_: Throwable) { false }
                        main.post { result.success(ok) }
                    }.start()
                }
                "deleteUri" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    Thread {
                        val ok = try { deleteUri(app, uri) } catch (_: Throwable) { false }
                        main.post { result.success(ok) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun matches(name: String, exts: List<String>) =
        exts.isEmpty() || exts.any { name.lowercase().endsWith(".$it") }

    private fun listFiles(context: Context, exts: List<String>, tree: String?): List<Map<String, Any?>> {
        val out = LinkedHashMap<String, Map<String, Any?>>()
        fun add(uri: String, name: String, size: Long, modifiedSec: Long) {
            if (matches(name, exts) && !out.containsKey(name)) {
                out[name] = mapOf("uri" to uri, "name" to name, "size" to size, "modified" to modifiedSec)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val projection = arrayOf(MediaStore.Downloads._ID, MediaStore.Downloads.DISPLAY_NAME,
                MediaStore.Downloads.SIZE, MediaStore.Downloads.DATE_MODIFIED)
            context.contentResolver.query(collection, projection, "${MediaStore.Downloads.RELATIVE_PATH} LIKE ?",
                arrayOf("${Environment.DIRECTORY_DOWNLOADS}/$FOLDER%"), null)?.use { c ->
                while (c.moveToNext()) {
                    add(android.net.Uri.withAppendedPath(collection, c.getLong(0).toString()).toString(),
                        c.getString(1) ?: "", c.getLong(2), c.getLong(3))
                }
            }
        }
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), FOLDER)
        dir.listFiles()?.filter { it.isFile }?.forEach {
            add(android.net.Uri.fromFile(it).toString(), it.name, it.length(), it.lastModified() / 1000L)
        }
        if (!tree.isNullOrEmpty()) {
            val treeUri = android.net.Uri.parse(tree)
            val children = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri, android.provider.DocumentsContract.getTreeDocumentId(treeUri))
            val cols = arrayOf(android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                android.provider.DocumentsContract.Document.COLUMN_SIZE,
                android.provider.DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            context.contentResolver.query(children, cols, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val doc = android.provider.DocumentsContract.buildDocumentUriUsingTree(treeUri, c.getString(0))
                    add(doc.toString(), c.getString(1) ?: "", c.getLong(2), c.getLong(3) / 1000L)
                }
            }
        }
        return out.values.toList()
    }

    private fun copyUri(context: Context, uri: String, target: File): Boolean {
        target.parentFile?.mkdirs()
        val tmp = File(target.path + ".part")
        val parsed = android.net.Uri.parse(uri)
        val input = if (parsed.scheme == "file") File(parsed.path ?: "").inputStream()
            else context.contentResolver.openInputStream(parsed) ?: return false
        input.use { i -> tmp.outputStream().use { o -> i.copyTo(o, 1 shl 20) } }
        if (target.exists()) target.delete()
        return tmp.renameTo(target)
    }

    private fun deleteUri(context: Context, uri: String): Boolean {
        val parsed = android.net.Uri.parse(uri)
        if (parsed.scheme == "file") return File(parsed.path ?: "").delete()
        return try {
            android.provider.DocumentsContract.deleteDocument(context.contentResolver, parsed)
        } catch (_: Throwable) {
            context.contentResolver.delete(parsed, null, null) > 0
        }
    }

    private fun copyToDownloads(context: Context, source: File, name: String, mime: String): Boolean {
        if (!source.isFile || name.isBlank()) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            @Suppress("DEPRECATION")
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), FOLDER)
            if (!dir.exists() && !dir.mkdirs()) return false
            val target = File(dir, name)
            val tmp = File(dir, "$name.part")
            source.inputStream().use { input -> tmp.outputStream().use { input.copyTo(it, 1 shl 20) } }
            if (tmp.length() != source.length()) { tmp.delete(); return false }
            return tmp.renameTo(target)
        }
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/$FOLDER/")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
            ?: return false
        try {
            val out = resolver.openOutputStream(uri) ?: throw IllegalStateException("no stream")
            out.use { os -> source.inputStream().use { it.copyTo(os, 1 shl 20) } }
            val size = resolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L
            if (size != source.length()) throw IllegalStateException("short write")
            resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            return true
        } catch (e: Throwable) {
            try { resolver.delete(uri, null, null) } catch (_: Throwable) {}
            return false
        }
    }
}
