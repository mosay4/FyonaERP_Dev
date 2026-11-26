package com.fyona.erp.fyona_flutter

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Why did the app stop last time? (Android 11+ ApplicationExitInfo.)
 *
 * "lastExit" returns, once, a plain-text report of the app's freezes (ANR)
 * and crashes since the previous call — reason, time, description and the
 * system's stack trace — or null. Only thread stacks and system text, no
 * user data. Read on a background thread (never blocks the UI).
 */
object ExitDiagnostics {
    private const val NAME = "com.fyona.erp/diagnostics"
    private const val PREFS = "fyona_exit_diag"
    private const val SEEN = "seen_ts"
    private const val MAX_TRACE = 120 * 1024

    fun register(context: Context, messenger: BinaryMessenger) {
        val main = Handler(Looper.getMainLooper())
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            if (call.method != "lastExit") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            Thread {
                val report = try { collect(context.applicationContext) } catch (_: Throwable) { null }
                main.post { result.success(report) }
            }.start()
        }
    }

    private fun collect(context: Context): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val am = context.getSystemService(ActivityManager::class.java) ?: return null
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val seen = prefs.getLong(SEEN, -1L)
        val all = am.getHistoricalProcessExitReasons(context.packageName, 0, 10)
        if (all.isEmpty()) return null
        val newest = all.maxOf { it.timestamp }
        prefs.edit().putLong(SEEN, newest).apply()
        // First run of this build: only remember where we are.
        if (seen < 0) return null
        val wanted = setOf(
            ApplicationExitInfo.REASON_ANR,
            ApplicationExitInfo.REASON_CRASH,
            ApplicationExitInfo.REASON_CRASH_NATIVE,
        )
        val fresh = all.filter { it.timestamp > seen && it.reason in wanted }
        if (fresh.isEmpty()) return null
        val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
        val sb = StringBuilder()
        sb.append("FYONA exit report\n")
        sb.append("device=${Build.MANUFACTURER} ${Build.MODEL} sdk=${Build.VERSION.SDK_INT}\n")
        try {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            sb.append("app=${info.versionName}\n")
        } catch (_: Throwable) {}
        for (e in fresh.sortedBy { it.timestamp }) {
            val kind = when (e.reason) {
                ApplicationExitInfo.REASON_ANR -> "ANR"
                ApplicationExitInfo.REASON_CRASH -> "CRASH"
                else -> "CRASH_NATIVE"
            }
            sb.append("\n=== $kind at ${fmt.format(Date(e.timestamp))} ===\n")
            sb.append("description=${e.description}\n")
            sb.append("importance=${e.importance} pss=${e.pss} rss=${e.rss}\n")
            // ANR traces are text; native tombstones are binary (skipped).
            if (e.reason == ApplicationExitInfo.REASON_ANR) try {
                e.traceInputStream?.use { stream ->
                    val bytes = stream.readBytes()
                    val text = String(bytes, Charsets.UTF_8)
                    // The "main" thread first: that is where an ANR lives.
                    val mainAt = text.indexOf("\"main\"")
                    val start = if (mainAt > 0) mainAt else 0
                    sb.append(text, start, minOf(text.length, start + MAX_TRACE))
                    sb.append('\n')
                }
            } catch (_: Throwable) {}
        }
        return sb.toString()
    }
}
