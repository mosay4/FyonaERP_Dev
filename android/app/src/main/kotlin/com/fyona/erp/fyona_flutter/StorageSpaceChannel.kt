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
                else -> result.notImplemented()
            }
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
