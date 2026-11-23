package com.fyona.erp.fyona_flutter

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import java.io.File
import java.io.OutputStream
import java.util.UUID
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import kotlin.system.exitProcess

/**
 * Shared exact-alarm pipeline used by MainActivity, AlarmReceiver and
 * BootReceiver. Carries ALL reminder fields in the alarm extras so the
 * receiver can post the right channel / tap route without Dart running.
 *
 * Alarm extras contract (AlarmReceiver input):
 *  - title, body: String
 *  - kind: "debt" | "recurring" (legacy debt alarms omit it → "debt")
 *  - refId: stable id (debt id for kind=debt)
 *  - debtId: legacy alias of refId for kind=debt (kept so PendingIntents
 *    scheduled by older builds still resolve)
 *  - requestCode: Int, Dart-provided stable code (FNV) — used AS-IS for
 *    PendingIntent identity AND notification id. Never recomputed here.
 *  - route: String tap route ("" = none)
 *
 * Notification extras contract (MainActivity tap bridge):
 *  - fyona_notif_kind / fyona_notif_refId / fyona_notif_route
 *  (+ legacy alarm_debt_id / debtId / from_alarm for kind=debt)
 */
internal object ReminderAlarmScheduler {
    const val DEBT_CHANNEL_ID = "debt_alarm_channel_v2"
    const val RECURRING_CHANNEL_ID = "recurring_channel"

    fun scheduleExact(
        context: Context,
        millis: Long,
        title: String,
        body: String,
        kind: String,
        refId: String,
        requestCode: Int,
        route: String
    ) {
        // One-time stale-channel migration + ensure, so the channel the
        // alarm will post to always exists with the right sound — even if
        // this schedule call is the first native code to run (boot re-arm).
        try {
            migrateStaleChannelsOnce(context)
            if (kind == "recurring") ensureRecurringChannel(context) else ensureDebtChannel(context)
        } catch (_: Exception) {}
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, AlarmReceiver::class.java).apply {
            putExtra("title", title)
            putExtra("body", body)
            putExtra("kind", kind)
            putExtra("refId", refId)
            if (kind == "debt") putExtra("debtId", refId)
            putExtra("requestCode", requestCode)
            putExtra("route", route)
        }
        val pi = PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // setAlarmClock on API≥S with permission for max reliability
        // (alarm icon, bypasses Doze/aggressive OEMs); fallbacks mirror the
        // previous debt-only logic. WAKE_LOCK permission stays declared;
        // RTC_WAKEUP wakes the device, no explicit wake lock needed.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (am.canScheduleExactAlarms()) {
                    val clockInfo = AlarmManager.AlarmClockInfo(millis, pi)
                    am.setAlarmClock(clockInfo, pi)
                } else {
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, millis, pi)
                }
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, millis, pi)
            } else {
                am.setExact(AlarmManager.RTC_WAKEUP, millis, pi)
            }
        } catch (e: SecurityException) {
            // Exact alarm not permitted — use inexact as fallback
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, millis, pi)
        }
    }

    fun cancelExact(context: Context, requestCode: Int) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        // NOTE: PendingIntent equality ignores extras, so this bare intent
        // matches the scheduled one as long as requestCode + flags match
        // (FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE used consistently).
        val intent = Intent(context, AlarmReceiver::class.java)
        val pi = PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        try { am.cancel(pi) } catch (_: Exception) {}
        // Also cancel notification if shown
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(requestCode)
        } catch (_: Exception) {}
    }

    fun soundUri(context: Context): Uri =
        Uri.parse("android.resource://${context.packageName}/raw/sound_2")

    /**
     * Debt channel — same config as before (sound_2, vibration, DND bypass,
     * badge, public lockscreen). With [reset] = true the previous channel
     * incarnation is deleted first so already-installed devices pick up the
     * sound (channel sound is immutable once created).
     */
    fun ensureDebtChannel(context: Context, reset: Boolean = false) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        if (reset) {
            try { nm.deleteNotificationChannel(DEBT_CHANNEL_ID) } catch (_: Exception) {}
        } else {
            try {
                if (nm.getNotificationChannel(DEBT_CHANNEL_ID) != null) return
            } catch (_: Exception) {}
        }
        val audioAttr = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val channel = NotificationChannel(
            DEBT_CHANNEL_ID,
            "تنبيهات الديون",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "تنبيه عند استحقاق الدين"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 500, 200, 500, 200, 500)
            setSound(soundUri(context), audioAttr)
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            enableLights(true)
            lightColor = 0xFF7A1020.toInt()
            setShowBadge(true)
            setBypassDnd(true)
        }
        try { nm.createNotificationChannel(channel) } catch (_: Exception) {}
    }

    /**
     * Recurring-reminder channel: HIGH + sound_2 + vibration + badge +
     * public lockscreen. Created natively (never reset) since
     * flutter_local_notifications may never run when the app is killed.
     * No DND bypass, no full-screen intent — normal heads-up suffices.
     */
    fun ensureRecurringChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        try {
            if (nm.getNotificationChannel(RECURRING_CHANNEL_ID) != null) return
        } catch (_: Exception) {}
        val audioAttr = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val channel = NotificationChannel(
            RECURRING_CHANNEL_ID,
            "التذكيرات الدورية",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "تذكيرات مجدولة — إشعار عادي مع صوت"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 400, 200, 400)
            setSound(soundUri(context), audioAttr)
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            enableLights(true)
            lightColor = 0xFF7A1020.toInt()
            setShowBadge(true)
        }
        try { nm.createNotificationChannel(channel) } catch (_: Exception) {}
    }

    private const val MIGRATION_PREFS = "fyona_notif_migrate"
    private const val MIGRATION_KEY = "channels_v2_reset_done"

    /**
     * One-time migration for devices carrying STALE channel configs (e.g. a
     * debt channel created long ago with a different sound — Android keeps
     * channel settings forever once created). Deletes both reminder
     * channels once so the ensures below recreate them with sound_2.
     * Runs wherever first reached (cold start, alarm fire, boot) — the
     * flag makes it exactly-once, so user customizations are never wiped
     * on every launch.
     */
    fun migrateStaleChannelsOnce(context: Context) {
        try {
            val sp = context.getSharedPreferences(MIGRATION_PREFS, Context.MODE_PRIVATE)
            if (sp.getBoolean(MIGRATION_KEY, false)) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = context.getSystemService(NotificationManager::class.java) ?: return
                try { nm.deleteNotificationChannel(DEBT_CHANNEL_ID) } catch (_: Exception) {}
                try { nm.deleteNotificationChannel(RECURRING_CHANNEL_ID) } catch (_: Exception) {}
            }
            try { sp.edit().putBoolean(MIGRATION_KEY, true).apply() } catch (_: Exception) {}
        } catch (_: Exception) {}
    }
}

class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val CHANNEL = "com.fyona.erp/alarm_native"
        private const val BACKUP_CHANNEL = "com.fyona.erp/backup_storage"
        private const val PRINT_CHANNEL = "fyona/printing"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val PREFS_KEY = "flutter.debt_reminders_v2"
        private const val FYONA_FOLDER = "FYONA ERP"
        private const val TAG = "FYONA_BACKUP"
    }

    private var pendingBackupResult: MethodChannel.Result? = null
    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingTreeResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    // ── Notification-tap bridge ──
    // Last tap payload from a reminder notification: cold start captures it
    // in onCreate/configureFlutterEngine, warm taps in onNewIntent.
    // Consumed (and cleared) by getInitialAlarmPayload so Dart routes once.
    private var pendingAlarmKind: String? = null
    private var pendingAlarmRefId: String? = null
    private var pendingAlarmRoute: String? = null

    // Pending MethodChannel result for the runtime POST_NOTIFICATIONS ask.
    private var pendingNotifPermissionResult: MethodChannel.Result? = null

    // ── Bluetooth ESC/POS printing (Business) ──
    private var btSocket: BluetoothSocket? = null
    private var btOut: OutputStream? = null
    private val btSppUuid: UUID =
        UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private val notifPermissionLauncher: ActivityResultLauncher<String> =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            val pending = pendingNotifPermissionResult
            pendingNotifPermissionResult = null
            try { pending?.success(granted) } catch (_: Exception) {}
        }

    private val permissionLauncher: ActivityResultLauncher<Array<String>> =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
            val pending = pendingPermissionResult
            pendingPermissionResult = null
            val granted = grants[android.Manifest.permission.WRITE_EXTERNAL_STORAGE] == true
            Log.i(TAG, "WRITE_EXTERNAL_STORAGE runtime result: granted=$granted")
            pending?.success(mapOf(
                "granted" to granted,
                "needed" to true,
                "androidVersion" to Build.VERSION.SDK_INT
            ))
        }

    private val pickTreeLauncher: ActivityResultLauncher<Intent> =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val pending = pendingTreeResult
            pendingTreeResult = null
            if (result.resultCode == RESULT_OK) {
                val treeUri = result.data?.data
                if (treeUri != null) {
                    try {
                        contentResolver.takePersistableUriPermission(
                            treeUri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        )
                    } catch (_: Exception) {}
                    val name = getTreeDisplayName(treeUri)
                    Log.i(TAG, "Folder tree picked: uri=$treeUri name=$name")
                    pending?.success(mapOf(
                        "success" to true,
                        "uri" to treeUri.toString(),
                        "name" to name
                    ))
                } else {
                    pending?.success(mapOf("success" to false, "message" to "لم يتم اختيار مجلد"))
                }
            } else {
                pending?.success(mapOf("success" to false, "message" to "تم الإلغاء"))
            }
        }

    private val pickDocumentLauncher: ActivityResultLauncher<Intent> =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val pending = pendingPickResult
            pendingPickResult = null
            if (result.resultCode == RESULT_OK) {
                val uri = result.data?.data
                if (uri != null) {
                    try {
                        contentResolver.takePersistableUriPermission(
                            uri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION
                        )
                    } catch (_: Exception) {}
                    val name = getFileName(uri)
                    val size = getFileSize(uri)
                    Log.i(TAG, "Document picked: uri=$uri name=$name size=$size")
                    pending?.success(mapOf(
                        "success" to true,
                        "uri" to uri.toString(),
                        "name" to name,
                        "size" to size
                    ))
                } else {
                    pending?.success(mapOf("success" to false, "message" to "لم يتم اختيار ملف"))
                }
            } else {
                pending?.success(mapOf("success" to false, "message" to "تم الإلغاء"))
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Cold-start tap bridge: capture notification extras even if the
        // Flutter engine (configureFlutterEngine) attaches later.
        // Idempotent with handleAlarmIntent() there — same values stored.
        try { handleAlarmIntent(intent) } catch (_: Exception) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fyona/motion_audio")
            .setMethodCallHandler { call, result ->
                if (call.method == "canPlay") {
                    val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val notification = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    val dndAllows = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                        notification.currentInterruptionFilter == NotificationManager.INTERRUPTION_FILTER_ALL
                    result.success(audio.ringerMode == AudioManager.RINGER_MODE_NORMAL &&
                        audio.getStreamVolume(AudioManager.STREAM_SYSTEM) > 0 && dndAllows)
                } else result.notImplemented()
            }

        // One-time stale-channel migration + ensure, every cold start.
        // (The flag inside makes the delete exactly-once; ensures recreate
        // immediately so the channels always exist with sound_2.)
        try {
            ReminderAlarmScheduler.migrateStaleChannelsOnce(this)
            ReminderAlarmScheduler.ensureDebtChannel(this)
            ReminderAlarmScheduler.ensureRecurringChannel(this)
        } catch (_: Exception) {}

        // Ensure alarm can show over lock screen
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }

        // Handle alarm launch intent if app was started via full-screen alarm
        handleAlarmIntent(intent)

        // ── Business printing: Bluetooth ESC/POS transport ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PRINT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "btIsSupported" -> result.success(bluetoothAdapter() != null)
                    "btIsEnabled" -> result.success(bluetoothAdapter()?.isEnabled == true)
                    "btBondedDevices" -> {
                        try {
                            val a = bluetoothAdapter()
                            if (a == null) {
                                result.success(emptyList<Map<String, String>>())
                                return@setMethodCallHandler
                            }
                            val out = a.bondedDevices.map { d ->
                                mapOf(
                                    "name" to (d.name ?: "طابعة بلوتوث"),
                                    "address" to d.address
                                )
                            }
                            result.success(out)
                        } catch (e: SecurityException) {
                            result.error("permission", "صلاحية البلوتوث مطلوبة", null)
                        } catch (e: Exception) {
                            result.error("bt", e.message, null)
                        }
                    }
                    "btConnect" -> btConnect(call.argument<String>("address") ?: "", result)
                    "btWrite" -> btWrite(call.argument<ByteArray>("bytes"), result)
                    "btDisconnect" -> {
                        btDisconnect()
                        result.success(true)
                    }
                    "btIsConnected" -> result.success(btSocket?.isConnected == true)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialAlarmDebtId" -> {
                    // Legacy debt-tap lookup (kept for the current Dart debt
                    // flow): 1) legacy extras, 2) pending bridge payload when
                    // kind == debt. Intentionally NON-consuming — use
                    // getInitialAlarmPayload for consume-once semantics.
                    val legacy = intent.getStringExtra("alarm_debt_id") ?: intent.getStringExtra("debtId") ?: ""
                    if (legacy.isNotEmpty()) {
                        result.success(legacy)
                    } else if (pendingAlarmKind == "debt" && !pendingAlarmRefId.isNullOrEmpty()) {
                        result.success(pendingAlarmRefId)
                    } else {
                        result.success("")
                    }
                }
                "getInitialAlarmPayload" -> {
                    // Generic tap bridge: returns-and-clears {kind, refId, route}.
                    val k = pendingAlarmKind
                    val r = pendingAlarmRefId
                    if (!k.isNullOrEmpty() && !r.isNullOrEmpty()) {
                        val route = pendingAlarmRoute ?: ""
                        pendingAlarmKind = null
                        pendingAlarmRefId = null
                        pendingAlarmRoute = null
                        result.success(mapOf("kind" to k, "refId" to r, "route" to route))
                    } else {
                        result.success(null)
                    }
                }
                "createAlarmChannel" -> {
                    createAlarmChannel()
                    result.success(true)
                }
                "scheduleExactAlarm" -> {
                    // Legacy debt path (kept): same signature as before.
                    val args = call.arguments as? Map<*, *>
                    val millis = numberArg(args, "millis", 0L)
                    val title = (args?.get("title") as? String) ?: "تنبيه الدين"
                    val body = (args?.get("body") as? String) ?: "لديك دين مستحق"
                    val debtId = (args?.get("debtId") as? String) ?: ""
                    val requestCode = if (args?.containsKey("requestCode") == true) {
                        numberArg(args, "requestCode", 0L).toInt()
                    } else {
                        debtId.hashCode()
                    }
                    scheduleNativeAlarm(millis, title, body, debtId, requestCode)
                    result.success(true)
                }
                "cancelExactAlarm" -> {
                    val args = call.arguments as? Map<*, *>
                    val requestCode = numberArg(args, "requestCode", 0L).toInt()
                    cancelNativeAlarm(requestCode)
                    result.success(true)
                }
                "scheduleReminderAlarm" -> {
                    // Generalized pipeline: kind recurring|debt.
                    // requestCode is the Dart-provided stable int (FNV) — used as-is.
                    val args = call.arguments as? Map<*, *>
                    val millis = numberArg(args, "millis", 0L)
                    val title = (args?.get("title") as? String) ?: "تذكير"
                    val body = (args?.get("body") as? String) ?: ""
                    val kind = ((args?.get("kind") as? String) ?: "recurring").lowercase()
                    val refId = (args?.get("refId") as? String) ?: ""
                    val requestCode = numberArg(args, "requestCode", 0L).toInt()
                    val route = (args?.get("route") as? String) ?: ""
                    val safeKind = if (kind == "debt") "debt" else "recurring"
                    ReminderAlarmScheduler.scheduleExact(this, millis, title, body, safeKind, refId, requestCode, route)
                    result.success(true)
                }
                "cancelReminderAlarm" -> {
                    val args = call.arguments as? Map<*, *>
                    val requestCode = numberArg(args, "requestCode", 0L).toInt()
                    ReminderAlarmScheduler.cancelExact(this, requestCode)
                    result.success(true)
                }
                "requestExactAlarmPermission" -> {
                    requestExactAlarmPermission()
                    result.success(true)
                }
                "requestBatteryExemption" -> {
                    requestBatteryExemption()
                    result.success(true)
                }
                "requestFullScreenIntentPermission" -> {
                    requestFullScreenIntentPermission()
                    result.success(true)
                }
                "areNotificationsEnabled" -> {
                    result.success(areNotificationsEnabled())
                }
                "requestNotificationsPermission" -> {
                    requestNotificationsPermissionAsync(result)
                }
                "canScheduleExactAlarms" -> {
                    result.success(canScheduleExact())
                }
                "canUseFullScreenIntent" -> {
                    result.success(canUseFullScreenIntent())
                }
                "isIgnoringBatteryOptimization" -> {
                    result.success(isIgnoringBatteryOptimization())
                }
                "showImmediateAlarm" -> {
                    val title = call.argument<String>("title") ?: "تنبيه الدين"
                    val body = call.argument<String>("body") ?: "لديك دين مستحق"
                    val debtId = call.argument<String>("debtId") ?: ""
                    val requestCode = debtId.hashCode()
                    showImmediateNotification(title, body, debtId, requestCode)
                    result.success(true)
                }
                "restartApp" -> {
                    restartApp()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ── Backup Storage Channel ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKUP_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    val fileName = call.argument<String>("fileName") ?: ""
                    val content = call.argument<String>("content") ?: ""
                    saveToDownloadsViaMediaStore(fileName, content, result)
                }
                "saveFileBytes" -> {
                    val fileName = call.argument<String>("fileName") ?: ""
                    val bytes = call.argument<ByteArray>("bytes")
                    val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
                    saveBytesToDownloads(fileName, bytes, mime, result)
                }
                "saveAtomic" -> {
                    val fileName = call.argument<String>("fileName") ?: ""
                    val content = call.argument<String>("content") ?: ""
                    saveAtomicToDownloads(fileName, content, result)
                }
                "pickDocument" -> {
                    val anyType = call.argument<Boolean>("anyType") ?: false
                    pickDocumentFromSaf(result, anyType)
                }
                "pickBackupFolder" -> {
                    pickBackupFolderFromSaf(result)
                }
                "readDocumentContent" -> {
                    val uriStr = call.argument<String>("uri") ?: ""
                    readDocumentByUri(uriStr, result)
                }
                "updateExistingBackup" -> {
                    val uriStr = call.argument<String>("uri") ?: ""
                    val content = call.argument<String>("content") ?: ""
                    updateExistingBackup(uriStr, content, result)
                }
                "overwriteFixedBackup" -> {
                    val uriStr = call.argument<String>("uri") ?: ""
                    val content = call.argument<String>("content") ?: ""
                    overwriteFixedBackup(uriStr, content, result)
                }
                "deleteBackupByUri" -> {
                    val uriStr = call.argument<String>("uri") ?: ""
                    deleteBackupByUri(uriStr, result)
                }
                "openFileInManager" -> {
                    val uriStr = call.argument<String>("uri") ?: ""
                    openFileInFileManager(uriStr)
                    result.success(true)
                }
                "listBackups" -> {
                    listExistingBackups(result)
                }
                "findBackupFile" -> {
                    val fileName = call.argument<String>("fileName") ?: ""
                    findBackupFileByName(fileName, result)
                }
                "requestStoragePermission" -> {
                    requestStoragePermission(result)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleAlarmIntent(intent)
        // Notify Flutter of taps while the app is alive. Debt keeps the
        // legacy callback; recurring uses the generic one (both are also
        // available pull-style via getInitialAlarmPayload).
        try {
            val kind = intent.getStringExtra("fyona_notif_kind")
                ?: if (!intent.getStringExtra("alarm_debt_id").isNullOrEmpty() || !intent.getStringExtra("debtId").isNullOrEmpty()) "debt" else null
            val refId = intent.getStringExtra("fyona_notif_refId")
                ?: intent.getStringExtra("alarm_debt_id")
                ?: intent.getStringExtra("debtId") ?: ""
            if (!kind.isNullOrEmpty() && refId.isNotEmpty() && flutterEngine != null) {
                val ch = MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, CHANNEL)
                if (kind == "debt") {
                    ch.invokeMethod("onAlarmReceived", mapOf("debtId" to refId))
                } else {
                    ch.invokeMethod("onReminderReceived", mapOf(
                        "kind" to kind,
                        "refId" to refId,
                        "route" to (intent.getStringExtra("fyona_notif_route") ?: "")
                    ))
                }
            }
        } catch (_: Exception) {}
    }

    private fun handleAlarmIntent(intent: Intent?) {
        if (intent == null) return
        val fromAlarm = intent.getBooleanExtra("from_alarm", false)
        if (fromAlarm) {
            // Ensure window can show over lock screen
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            }
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        // ── Tap bridge: remember the payload for getInitialAlarmPayload ──
        // New extras (posted by AlarmReceiver) + legacy debt extras.
        val kind = intent.getStringExtra("fyona_notif_kind")
            ?: if (!intent.getStringExtra("alarm_debt_id").isNullOrEmpty() || !intent.getStringExtra("debtId").isNullOrEmpty()) "debt" else null
        val refId = intent.getStringExtra("fyona_notif_refId")
            ?: intent.getStringExtra("alarm_debt_id")
            ?: intent.getStringExtra("debtId") ?: ""
        val route = intent.getStringExtra("fyona_notif_route") ?: ""
        if (!kind.isNullOrEmpty() && refId.isNotEmpty()) {
            pendingAlarmKind = kind
            pendingAlarmRefId = refId
            pendingAlarmRoute = route
        }
    }

    /**
     * Reads a numeric MethodChannel arg tolerantly: Dart ints arrive as
     * Integer or Long depending on magnitude (millis always exceeds Int
     * range), and FNV requestCodes may arrive as either.
     */
    private fun numberArg(args: Map<*, *>?, key: String, def: Long): Long {
        return when (val v = args?.get(key)) {
            is Number -> v.toLong()
            is String -> v.toLongOrNull() ?: def
            else -> def
        }
    }

    private fun createAlarmChannel() {
        // Debt channel is reset (delete + recreate) so already-installed
        // devices pick up the sound; recurring channel is created if missing.
        // Both are also ensured natively in AlarmReceiver for the killed-app
        // case where Dart never runs.
        ReminderAlarmScheduler.ensureDebtChannel(this, reset = true)
        ReminderAlarmScheduler.ensureRecurringChannel(this)
    }

    private fun scheduleNativeAlarm(millis: Long, title: String, body: String, debtId: String, requestCode: Int) {
        // Legacy debt path → generalized pipeline (kind=debt, empty route).
        ReminderAlarmScheduler.scheduleExact(this, millis, title, body, "debt", debtId, requestCode, "")
    }

    private fun cancelNativeAlarm(requestCode: Int) {
        ReminderAlarmScheduler.cancelExact(this, requestCode)
    }

    /**
     * True cold restart: schedules a relaunch of the launch activity ~400ms
     * in the future, then kills the process. The app disappears from the
     * foreground AND restarts by itself with a fresh Flutter engine, so the
     * user lands on up-to-date data (used after a full data reset).
     */
    private fun restartApp() {
        try {
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            } ?: Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            }
            val pi = PendingIntent.getActivity(
                this,
                987654321,
                launchIntent,
                PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val triggerAt = System.currentTimeMillis() + 400
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
                } else {
                    am.setExact(AlarmManager.RTC_WAKEUP, triggerAt, pi)
                }
            } catch (_: SecurityException) {
                am.set(AlarmManager.RTC_WAKEUP, triggerAt, pi)
            }
        } catch (_: Exception) {}
        // Give the MethodChannel result a chance to flush, then die.
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            try { finishAffinity() } catch (_: Exception) {}
            try { android.os.Process.killProcess(android.os.Process.myPid()) } catch (_: Exception) {}
            exitProcess(0)
        }, 250)
    }

    private fun showImmediateNotification(title: String, body: String, debtId: String, requestCode: Int) {
        // Foreground/immediate path (kept signature): normal high-priority
        // heads-up with sound_2 — no full-screen intent, no AlarmActivity.
        ReminderAlarmScheduler.ensureDebtChannel(this)
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("fyona_notif_kind", "debt")
            putExtra("fyona_notif_refId", debtId)
            putExtra("fyona_notif_route", "")
            putExtra("alarm_debt_id", debtId)
            putExtra("from_alarm", true)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            requestCode,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val soundUri = ReminderAlarmScheduler.soundUri(this)
        val notification = NotificationCompat.Builder(this, ReminderAlarmScheduler.DEBT_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setOngoing(false)
            .setSound(soundUri)
            .setVibrate(longArrayOf(0, 500, 200, 500, 200, 500))
            .setColor(0xFF000000.toInt())
            .build()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(requestCode, notification)
    }

    private fun canScheduleExact(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            return am.canScheduleExactAlarms()
        }
        return true
    }

    private fun canUseFullScreenIntent(): Boolean {
        // Full-screen alarms were removed (plain heads-up + sound_2 now), so
        // there is nothing to gate — always report granted to keep the Dart
        // flow moving. Kept only so the existing channel method keeps working.
        return true
    }

    private fun isIgnoringBatteryOptimization(): Boolean {
        return try {
            val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } catch (_: Exception) { true }
    }

    private fun areNotificationsEnabled(): Boolean {
        return try {
            NotificationManagerCompat.from(this).areNotificationsEnabled()
        } catch (_: Exception) { true }
    }

    /**
     * Actually requests POST_NOTIFICATIONS on SDK 33+ via the system dialog
     * (Activity Result API — equivalent to ActivityCompat.requestPermissions)
     * and replies with the grant result. Pre-33, or when already granted,
     * replies immediately with the current state. Any stale pending request
     * is completed (false) before a new one starts.
     */
    private fun requestNotificationsPermissionAsync(result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT < 33) {
                result.success(areNotificationsEnabled())
                return
            }
            if (areNotificationsEnabled()) {
                result.success(true)
                return
            }
            try { pendingNotifPermissionResult?.success(false) } catch (_: Exception) {}
            pendingNotifPermissionResult = result
            try {
                notifPermissionLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)
            } catch (_: Exception) {
                pendingNotifPermissionResult = null
                result.success(false)
            }
        } catch (_: Exception) {
            try { result.success(false) } catch (_: Exception) {}
        }
    }

    private fun requestExactAlarmPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                intent.data = Uri.parse("package:$packageName")
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
            } catch (_: Exception) {}
        }
    }

    private fun requestFullScreenIntentPermission() {
        if (Build.VERSION.SDK_INT >= 34) {
            try {
                val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
                intent.data = Uri.parse("package:$packageName")
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
            } catch (_: Exception) {
                // Fallback for devices that don't support this intent
                try {
                    val intent2 = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    intent2.data = Uri.parse("package:$packageName")
                    intent2.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent2)
                } catch (_: Exception) {}
            }
        }
    }

    private fun requestBatteryExemption() {
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            intent.data = Uri.parse("package:$packageName")
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (_: Exception) {
            try {
                val intent2 = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                intent2.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent2)
            } catch (_: Exception) {}
        }
    }

    // ════════════════════════════════════════════════
    //  BACKUP STORAGE — MediaStore + SAF (Scoped Storage)
    // ════════════════════════════════════════════════

    private fun buildInitialUri(): Uri? {
        // 1) Prefer a user-picked folder persisted as a tree URI.
        try {
            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val tree = prefs.getString("flutter.backup_saved_tree_uri", null)
            if (!tree.isNullOrEmpty()) {
                val t = Uri.parse(tree)
                if (t.scheme == "content") {
                    val docId = DocumentsContract.getTreeDocumentId(t)
                    val docUri = DocumentsContract.buildDocumentUriUsingTree(t, docId)
                    Log.i(TAG, "Initial folder URI from saved tree: $docUri")
                    return docUri
                }
            }
        } catch (_: Exception) {}
        // 2) Fallback: the logical Download/FYONA ERP document.
        return try {
            DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents",
                "primary:Download/$FYONA_FOLDER"
            )
        } catch (_: Exception) { null }
    }

    private fun saveToDownloadsViaMediaStore(fileName: String, content: String, result: MethodChannel.Result) {
        val contentBytes = content.toByteArray(Charsets.UTF_8)
        Log.i(TAG, "Backup save: SDK=${Build.VERSION.SDK_INT}, fileName=$fileName, contentBytes=${contentBytes.size}")

        if (contentBytes.isEmpty()) {
            Log.e(TAG, "Backup save aborted: content is empty")
            result.success(mapOf("success" to false, "message" to "البيانات فارغة — لا يمكن الحفظ"))
            return
        }

        // Android 9 and below: MediaStore Downloads collection does not exist.
        // Use the classic shared-storage file path with WRITE_EXTERNAL_STORAGE.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            saveToDownloadsLegacy(fileName, contentBytes, content, result)
            return
        }

        val relativePath = Environment.DIRECTORY_DOWNLOADS + "/$FYONA_FOLDER"
        val relativePathWithSlash = "$relativePath/"
        val resolver = contentResolver
        var fileUri: Uri? = null

        try {
            val contentValues = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, "application/json")
                put(MediaStore.Downloads.RELATIVE_PATH, relativePathWithSlash)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }

            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            fileUri = resolver.insert(collection, contentValues)
            if (fileUri == null) {
                Log.e(TAG, "MediaStore.insert returned null URI")
                result.success(mapOf("success" to false, "message" to "فشل إنشاء الملف في MediaStore"))
                return
            }
            Log.i(TAG, "MediaStore.insert OK: uri=$fileUri, display=$fileName, relative=$relativePath")

            // Write all bytes through ContentResolver.
            val opened = resolver.openOutputStream(fileUri)
            if (opened == null) {
                Log.e(TAG, "openOutputStream returned null; uri=$fileUri")
                deleteQuietly(fileUri)
                result.success(mapOf("success" to false, "message" to "فشل فتح الملف للكتابة"))
                return
            }
            opened.use { os ->
                os.write(contentBytes)
                os.flush()
            }
            Log.i(TAG, "Write done: bytes=${contentBytes.size}")

            // Make the file visible (un-pending).
            val pendingValues = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            val updated = resolver.update(fileUri, pendingValues, null, null)
            if (updated <= 0) {
                Log.e(TAG, "Failed to clear IS_PENDING; file may stay hidden")
                deleteQuietly(fileUri)
                result.success(mapOf("success" to false, "message" to "فشل إتمام إظهار الملف في MediaStore"))
                return
            }

            // ── Ground-truth verification (no blind trust) ──
            val statSize = try {
                resolver.openFileDescriptor(fileUri, "r")?.use { it.statSize } ?: 0L
            } catch (e: Exception) {
                Log.e(TAG, "statSize failed: ${e.message}")
                0L
            }
            val readBack = readUriContent(fileUri)
            val readOk = readBack != null && readBack.isNotEmpty() && readBack == content
            val rowFound = findDownloadRow(fileName, relativePathWithSlash)

            Log.i(TAG, "VERIFY: statSize=$statSize expected=${contentBytes.size} readBackOk=$readOk rowFound=${rowFound != null} path=$relativePathWithSlash")

            if (statSize <= 0 || !readOk || rowFound == null) {
                Log.e(TAG, "Backup verification FAILED — refusing to report success")
                deleteQuietly(fileUri)
                result.success(mapOf(
                    "success" to false,
                    "message" to "تم إنشاء الملف لكن التحقق من الكتابة فشل (الحجم $statSize)"
                ))
                return
            }

            val displayName = getFileName(fileUri)
            // المسار الفعلي للمستخدم داخل مجلد التنزيلات
            val filePath = "$relativePath/$fileName"
            Log.i(TAG, "Backup verified OK: uri=$fileUri, size=$statSize, path=$filePath")

            result.success(mapOf(
                "success" to true,
                "uri" to fileUri.toString(),
                "filePath" to filePath,
                "fileName" to displayName,
                "fileSize" to statSize,
                "relativePath" to relativePathWithSlash
            ))
        } catch (e: Exception) {
            Log.e(TAG, "saveToDownloads exception: ${e.message}", e)
            if (fileUri != null) deleteQuietly(fileUri)
            result.success(mapOf("success" to false, "message" to "خطأ أثناء الحفظ: ${e.message}"))
        }
    }

    /**
     * Atomic save: delete existing file with same name, then create fresh.
     * This ensures only one backup file exists at any time.
     */
    private fun saveAtomicToDownloads(fileName: String, content: String, result: MethodChannel.Result) {
        val contentBytes = content.toByteArray(Charsets.UTF_8)
        Log.i(TAG, "saveAtomic: SDK=${Build.VERSION.SDK_INT}, fileName=$fileName, bytes=${contentBytes.size}")

        if (contentBytes.isEmpty()) {
            result.success(mapOf("success" to false, "message" to "البيانات فارغة"))
            return
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            saveAtomicLegacy(fileName, contentBytes, content, result)
            return
        }

        val relativePath = Environment.DIRECTORY_DOWNLOADS + "/$FYONA_FOLDER"
        val relativePathWithSlash = "$relativePath/"
        val resolver = contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

        // ATOMIC rotate: the previous file (if any) is deleted ONLY after the
        // new row is written AND verified. Any failure keeps the old backup.
        var fileUri: Uri? = null
        try {
            // Step 1: Create new file with IS_PENDING (old file untouched)
            val contentValues = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, "application/json")
                put(MediaStore.Downloads.RELATIVE_PATH, relativePathWithSlash)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            fileUri = resolver.insert(collection, contentValues)
            if (fileUri == null) {
                result.success(mapOf("success" to false, "message" to "فشل إنشاء الملف"))
                return
            }

            // Step 2: Write content
            val os = resolver.openOutputStream(fileUri)
            if (os == null) {
                deleteQuietly(fileUri)
                result.success(mapOf("success" to false, "message" to "فشل فتح الملف للكتابة"))
                return
            }
            os.use { o ->
                o.write(contentBytes)
                o.flush()
            }

            // Step 3: Mark as complete
            val pendingValues = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            resolver.update(fileUri, pendingValues, null, null)

            // Step 4: Verify BEFORE touching the old file
            val statSize = try {
                resolver.openFileDescriptor(fileUri, "r")?.use { it.statSize } ?: 0L
            } catch (_: Exception) { 0L }
            val readBack = readUriContent(fileUri)
            val ok = statSize > 0 && readBack != null && readBack == content

            if (!ok) {
                deleteQuietly(fileUri)
                result.success(mapOf("success" to false, "message" to "فشل التحقق من الكتابة"))
                return
            }

            // The previous file (if any) is deleted EXPLICITLY by the Dart
            // layer via deleteBackupByUri with its exact known URI — never
            // by name matching here, so the new row can never be mistaken
            // for a stale one.

            val displayName = getFileName(fileUri)
            Log.i(TAG, "saveAtomic OK: uri=$fileUri size=$statSize")
            result.success(mapOf(
                "success" to true,
                "uri" to fileUri.toString(),
                "filePath" to "$relativePath/$fileName",
                "fileName" to displayName,
                "fileSize" to statSize,
                "relativePath" to relativePathWithSlash
            ))
        } catch (e: Exception) {
            Log.e(TAG, "saveAtomic exception: ${e.message}", e)
            try {
                fileUri?.let { deleteQuietly(it) }
            } catch (_: Exception) {}
            result.success(mapOf("success" to false, "message" to "خطأ: ${e.message}"))
        }
    }

    private fun saveAtomicLegacy(fileName: String, contentBytes: ByteArray, content: String, result: MethodChannel.Result) {
        if (checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            result.success(mapOf("success" to false, "message" to "صلاحية التخزين مطلوبة"))
            return
        }
        try {
            val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val folder = File(downloadDir, FYONA_FOLDER)
            if (!folder.exists() && !folder.mkdirs()) {
                result.success(mapOf("success" to false, "message" to "تعذر إنشاء المجلد"))
                return
            }
            val target = File(folder, fileName)
            // Atomic: write to temp, then rename
            val tempFile = File(folder, "${fileName}.tmp")
            tempFile.writeBytes(contentBytes)
            val readBack = tempFile.readText()
            if (readBack != content) {
                tempFile.delete()
                result.success(mapOf("success" to false, "message" to "فشل التحقق"))
                return
            }
            tempFile.renameTo(target)
            val size = target.length()
            result.success(mapOf(
                "success" to true,
                "uri" to Uri.fromFile(target).toString(),
                "filePath" to "Download/$FYONA_FOLDER/$fileName",
                "fileName" to fileName,
                "fileSize" to size
            ))
        } catch (e: Exception) {
            result.success(mapOf("success" to false, "message" to "خطأ: ${e.message}"))
        }
    }

    private fun saveToDownloadsLegacy(fileName: String, contentBytes: ByteArray, content: String, result: MethodChannel.Result) {
        if (checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            Log.e(TAG, "Legacy save aborted: WRITE_EXTERNAL_STORAGE not granted")
            result.success(mapOf("success" to false, "message" to "صلاحية التخزين مطلوبة على هذا الجهاز"))
            return
        }
        try {
            val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val folder = File(downloadDir, FYONA_FOLDER)
            if (!folder.exists() && !folder.mkdirs()) {
                result.success(mapOf("success" to false, "message" to "تعذر إنشاء مجلد FYONA ERP"))
                return
            }
            val target = File(folder, fileName)
            target.writeBytes(contentBytes)
            val size = target.length()
            val readBack = if (target.exists()) target.readText() else ""
            Log.i(TAG, "Legacy save verify: size=$size readOk=${readBack == content}")
            if (size <= 0 || readBack != content) {
                result.success(mapOf("success" to false, "message" to "فشل التحقق من الملف بعد الكتابة (الحجم $size)"))
                return
            }
            result.success(mapOf(
                "success" to true,
                "uri" to Uri.fromFile(target).toString(),
                "filePath" to "Download/$FYONA_FOLDER/$fileName",
                "fileName" to fileName,
                "fileSize" to size
            ))
        } catch (e: Exception) {
            Log.e(TAG, "Legacy save exception: ${e.message}", e)
            result.success(mapOf("success" to false, "message" to "خطأ أثناء الحفظ: ${e.message}"))
        }
    }

    private fun findDownloadRow(fileName: String, relativePath: String): Uri? {
        return try {
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val projection = arrayOf(MediaStore.Downloads._ID)
            // نستخدم LIKE للتسامح مع اختلاف وجود "/" النهائية بين الأجهزة
            val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} LIKE ?"
            val selectionArgs = arrayOf(fileName, relativePath.removeSuffix("/") + "%")
            val cursor = contentResolver.query(collection, projection, selection, selectionArgs, null)
            cursor?.use { c ->
                if (c.moveToFirst()) {
                    val id = c.getLong(c.getColumnIndexOrThrow(MediaStore.Downloads._ID))
                    Uri.withAppendedPath(collection, id.toString())
                } else {
                    null
                }
            } ?: null
        } catch (e: Exception) {
            Log.e(TAG, "findDownloadRow failed: ${e.message}")
            null
        }
    }

    private fun pickBackupFolderFromSaf(result: MethodChannel.Result) {
        pendingTreeResult = result
        val initialUri = buildInitialUri()
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            if (initialUri != null) putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri)
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
        }
        try {
            pickTreeLauncher.launch(intent)
        } catch (e: Exception) {
            pendingTreeResult = null
            result.success(mapOf("success" to false, "message" to "فشل فتح اختيار المجلد: ${e.message}"))
        }
    }

    private fun getTreeDisplayName(treeUri: Uri): String {
        return try {
            val docUri = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri)
            )
            contentResolver.query(docUri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                    if (idx >= 0) c.getString(idx) else null
                } else {
                    null
                }
            } ?: treeUri.lastPathSegment?.substringAfter(':') ?: FYONA_FOLDER
        } catch (_: Exception) {
            treeUri.lastPathSegment?.substringAfter(':') ?: FYONA_FOLDER
        }
    }

    private fun pickDocumentFromSaf(result: MethodChannel.Result, anyType: Boolean) {
        pendingPickResult = result
        val initialUri = buildInitialUri()
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            if (anyType) {
                type = "*/*"
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json"))
            } else {
                type = "application/json"
            }
            if (initialUri != null) putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        Log.i(TAG, "Launching ACTION_OPEN_DOCUMENT anyType=$anyType initial=$initialUri")
        try {
            pickDocumentLauncher.launch(intent)
        } catch (e: Exception) {
            pendingPickResult = null
            val fallback = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                if (initialUri != null) putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }
            try {
                pickDocumentLauncher.launch(fallback)
            } catch (e2: Exception) {
                result.success(mapOf("success" to false, "message" to "فشل فتح متصفح الملفات: ${e2.message}"))
            }
        }
    }

    private fun readDocumentByUri(uriStr: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriStr)
            val content = readUriContent(uri)
            if (content != null) {
                val size = getFileSize(uri)
                Log.i(TAG, "readDocumentByUri OK: uri=$uri size=$size readBytes=${content.toByteArray(Charsets.UTF_8).size}")
                result.success(mapOf(
                    "success" to true,
                    "content" to content,
                    "name" to getFileName(uri),
                    "size" to size
                ))
            } else {
                Log.e(TAG, "readDocumentByUri failed: uri=$uri")
                result.success(mapOf("success" to false, "message" to "فشل قراءة الملف"))
            }
        } catch (e: Exception) {
            Log.e(TAG, "readDocumentByUri exception: ${e.message}")
            result.success(mapOf("success" to false, "message" to "خطأ: ${e.message}"))
        }
    }

    private fun backupDisplayName(): String = "FYONA_ERP_Backup.json"

    private fun backupRelativePath(): String =
        Environment.DIRECTORY_DOWNLOADS + "/$FYONA_FOLDER/"

    // Collision-free overwrite of the fixed single-file backup
    // (FYONA_ERP_Backup.json): writes BYTES into the EXISTING row in
    // truncate mode instead of inserting a new row, so a stale same-name
    // MediaStore entry can never trigger "Failed to build unique file".
    // Retries from memory; only verified content replaces the old file.
    private fun overwriteFixedBackup(uriStr: String, content: String, result: MethodChannel.Result) {
        try {
            Log.i(TAG, "overwriteFixedBackup: uri=$uriStr bytes=${content.toByteArray(Charsets.UTF_8).size}")
            val uri = Uri.parse(uriStr)
            val contentBytes = content.toByteArray(Charsets.UTF_8)
            if (contentBytes.isEmpty()) {
                result.success(mapOf("success" to false, "message" to "البيانات فارغة"))
                return
            }

            if (uri.scheme == "file") {
                val file = File(uri.path ?: run {
                    result.success(mapOf("success" to false, "message" to "مسار الملف غير صالح"))
                    return
                })
                val folder = file.parentFile ?: run {
                    result.success(mapOf("success" to false, "message" to "مسار الملف غير صالح"))
                    return
                }
                val tempFile = File(folder, "${file.name}.tmp")
                tempFile.writeBytes(contentBytes)
                if (tempFile.readText() != content) {
                    try { tempFile.delete() } catch (_: Exception) {}
                    result.success(mapOf("success" to false, "message" to "فشل التحقق من الكتابة"))
                    return
                }
                if (!tempFile.renameTo(file)) {
                    try { tempFile.delete() } catch (_: Exception) {}
                    result.success(mapOf("success" to false, "message" to "فشل استبدال الملف"))
                    return
                }
                result.success(mapOf("success" to true, "uri" to uriStr, "fileSize" to file.length()))
                return
            }

            val resolver = contentResolver
            var lastErr = ""
            for (attempt in 1..2) {
                try {
                    val os = resolver.openOutputStream(uri, "wt")
                    if (os == null) {
                        lastErr = "فشل فتح الملف للكتابة"
                        continue
                    }
                    os.use { o ->
                        o.write(contentBytes)
                        o.flush()
                    }
                    val statSize = try {
                        resolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: 0L
                    } catch (_: Exception) { 0L }
                    val readBack = readUriContent(uri)
                    if (statSize > 0 && readBack != null && readBack == content) {
                        Log.i(TAG, "overwriteFixedBackup OK: uri=$uriStr size=$statSize attempt=$attempt")
                        result.success(mapOf("success" to true, "uri" to uriStr, "fileSize" to statSize))
                        return
                    }
                    lastErr = "فشل التحقق من الكتابة"
                } catch (e: Exception) {
                    lastErr = e.message ?: "خطأ غير معروف"
                }
            }
            result.success(mapOf("success" to false, "message" to "خطأ: $lastErr"))
        } catch (e: Exception) {
            result.success(mapOf("success" to false, "message" to "خطأ: ${e.message}"))
        }
    }

    // ATOMIC rotate for auto-backup updates: write a NEW row + verify, then
    // delete the old row. The previous backup always survives a failed
    // update. Returns the NEW uri (callers must persist it).
    // file:// URIs use tmp + verify + rename (same-directory atomic move).
    private fun updateExistingBackup(uriStr: String, content: String, result: MethodChannel.Result) {
        try {
            Log.i(TAG, "updateExistingBackup: uri=$uriStr bytes=${content.toByteArray(Charsets.UTF_8).size}")
            val uri = Uri.parse(uriStr)
            val contentBytes = content.toByteArray(Charsets.UTF_8)
            if (contentBytes.isEmpty()) {
                result.success(mapOf("success" to false, "message" to "البيانات فارغة"))
                return
            }

            if (uri.scheme == "file") {
                val file = File(uri.path ?: run {
                    result.success(mapOf("success" to false, "message" to "مسار الملف غير صالح"))
                    return
                })
                val folder = file.parentFile ?: run {
                    result.success(mapOf("success" to false, "message" to "مسار الملف غير صالح"))
                    return
                }
                val tempFile = File(folder, "${file.name}.tmp")
                tempFile.writeBytes(contentBytes)
                if (tempFile.readText() != content) {
                    try { tempFile.delete() } catch (_: Exception) {}
                    result.success(mapOf("success" to false, "message" to "فشل التحقق من الكتابة"))
                    return
                }
                if (!tempFile.renameTo(file)) {
                    try { tempFile.delete() } catch (_: Exception) {}
                    result.success(mapOf("success" to false, "message" to "فشل استبدال الملف"))
                    return
                }
                val statSize = file.length()
                result.success(mapOf("success" to true, "uri" to uriStr, "fileSize" to statSize))
                return
            }

            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                result.success(mapOf("success" to false, "message" to "غير مدعوم على هذا الإصدار"))
                return
            }
            // Same-name row already on disk: overwrite its bytes in place
            // instead of inserting. A fresh insert with a fixed DISPLAY_NAME
            // collides with stale rows ("Failed to build unique file") on
            // several devices; truncate-write never inserts, so it cannot
            // collide. Content is retried from memory; only verified bytes
            // replace the old file.
            val existing = findDownloadRow(backupDisplayName(), backupRelativePath())
            if (existing != null) {
                Log.i(TAG, "updateExistingBackup: same-name row exists, overwriting in place: $existing")
                var lastErr = ""
                var done = false
                for (attempt in 1..2) {
                    try {
                        val os = contentResolver.openOutputStream(existing, "wt")
                        if (os == null) {
                            lastErr = "فشل فتح الملف للكتابة"
                            continue
                        }
                        os.use { o ->
                            o.write(contentBytes)
                            o.flush()
                        }
                        val statSize = try {
                            contentResolver.openFileDescriptor(existing, "r")?.use { it.statSize } ?: 0L
                        } catch (_: Exception) { 0L }
                        val readBack = readUriContent(existing)
                        if (statSize > 0 && readBack != null && readBack == content) {
                            Log.i(TAG, "updateExistingBackup OK in place: uri=$existing size=$statSize attempt=$attempt")
                            result.success(mapOf(
                                "success" to true,
                                "uri" to existing.toString(),
                                "fileSize" to statSize,
                                "fileName" to backupDisplayName(),
                                "relativePath" to backupRelativePath()
                            ))
                            done = true
                            break
                        }
                        lastErr = "فشل التحقق من الكتابة"
                    } catch (e: Exception) {
                        lastErr = e.message ?: "خطأ غير معروف"
                    }
                }
                if (done) return
                result.success(mapOf("success" to false, "message" to "خطأ: $lastErr"))
                return
            }
            val resolver = contentResolver
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            var newUri: Uri? = null
            try {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, backupDisplayName())
                    put(MediaStore.Downloads.MIME_TYPE, "application/json")
                    put(MediaStore.Downloads.RELATIVE_PATH, backupRelativePath())
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                newUri = resolver.insert(collection, values)
                if (newUri == null) {
                    result.success(mapOf("success" to false, "message" to "فشل إنشاء الملف"))
                    return
                }
                val os = resolver.openOutputStream(newUri)
                if (os == null) {
                    deleteQuietly(newUri)
                    result.success(mapOf("success" to false, "message" to "فشل فتح الملف للكتابة"))
                    return
                }
                os.use { o ->
                    o.write(contentBytes)
                    o.flush()
                }
                resolver.update(newUri, ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                }, null, null)

                val statSize = try {
                    resolver.openFileDescriptor(newUri, "r")?.use { it.statSize } ?: 0L
                } catch (_: Exception) { 0L }
                val readBack = readUriContent(newUri)
                val ok = statSize > 0 && readBack != null && readBack == content
                Log.i(TAG, "updateExistingBackup verify: statSize=$statSize expected=${contentBytes.size} readOk=$ok")
                if (!ok) {
                    deleteQuietly(newUri)
                    result.success(mapOf("success" to false, "message" to "فشل التحقق من الكتابة (الحجم $statSize)"))
                    return
                }
                // Verified — the caller (Dart) retires the previous URI
                // explicitly. Nothing is deleted here by name matching.
                result.success(mapOf(
                    "success" to true,
                    "uri" to newUri.toString(),
                    "fileSize" to statSize,
                    "fileName" to getFileName(newUri),
                    "relativePath" to backupRelativePath()
                ))
            } catch (e: Exception) {
                try {
                    newUri?.let { deleteQuietly(it) }
                } catch (_: Exception) {}
                throw e
            }
        } catch (e: Exception) {
            Log.e(TAG, "updateExistingBackup exception: ${e.message}")
            result.success(mapOf("success" to false, "message" to "خطأ: ${e.message}"))
        }
    }

    private fun deleteBackupByUri(uriStr: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriStr)
            if (uri.scheme == "file") {
                val f = File(uri.path ?: run {
                    result.success(mapOf("success" to true))
                    return
                })
                if (f.exists()) f.delete()
            } else {
                contentResolver.delete(uri, null, null)
            }
            Log.i(TAG, "Backup deleted: $uri")
            result.success(mapOf("success" to true))
        } catch (e: Exception) {
            Log.e(TAG, "deleteBackupByUri exception: ${e.message}")
            result.success(mapOf("success" to false, "message" to "خطأ: ${e.message}"))
        }
    }

    private fun deleteQuietly(uri: Uri) {
        try {
            contentResolver.delete(uri, null, null)
        } catch (_: Exception) {}
    }

    private fun openFileInFileManager(uriStr: String) {
        try {
            val uri = Uri.parse(uriStr)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/json")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(Intent.createChooser(intent, "فتح الملف"))
        } catch (_: Exception) {}
    }

    private fun readUriContent(uri: Uri): String? {
        return try {
            if (uri.scheme == "file") {
                val f = File(uri.path ?: return null)
                if (f.exists()) f.readText() else null
            } else {
                contentResolver.openInputStream(uri)?.use { inputStream ->
                    java.io.BufferedReader(java.io.InputStreamReader(inputStream, Charsets.UTF_8)).use { reader ->
                        reader.readText()
                    }
                }
            }
        } catch (_: Exception) { null }
    }

    private fun getFileName(uri: Uri): String {
        var name = "unknown"
        if (uri.scheme == "content") {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
                    if (idx >= 0) {
                        name = cursor.getString(idx) ?: name
                    }
                }
            }
        }
        if (name == "unknown") {
            name = uri.lastPathSegment ?: "unknown"
        }
        return name
    }

    private fun getFileSize(uri: Uri): Long {
        return try {
            if (uri.scheme == "file") {
                File(uri.path ?: return 0L).length()
            } else {
                contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: 0L
            }
        } catch (_: Exception) { 0L }
    }

    private fun findBackupFileByName(fileName: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val relativePath = Environment.DIRECTORY_DOWNLOADS + "/$FYONA_FOLDER/"
            val uri = findDownloadRow(fileName, relativePath)
            if (uri != null) {
                result.success(mapOf("found" to true, "uri" to uri.toString(), "name" to fileName))
            } else {
                result.success(mapOf("found" to false))
            }
        } else {
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), FYONA_FOLDER)
            val target = File(dir, fileName)
            if (target.exists()) {
                result.success(mapOf("found" to true, "uri" to Uri.fromFile(target).toString(), "name" to fileName))
            } else {
                result.success(mapOf("found" to false))
            }
        }
    }

    private fun listExistingBackups(result: MethodChannel.Result) {
        try {
            val backups = mutableListOf<Map<String, Any?>>()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                val projection = arrayOf(
                    MediaStore.Downloads._ID,
                    MediaStore.Downloads.DISPLAY_NAME,
                    MediaStore.Downloads.SIZE,
                    MediaStore.Downloads.DATE_MODIFIED,
                    MediaStore.Downloads.RELATIVE_PATH
                )
                val selection = "${MediaStore.Downloads.RELATIVE_PATH} LIKE ? AND (${MediaStore.Downloads.DISPLAY_NAME} LIKE ? OR ${MediaStore.Downloads.DISPLAY_NAME} LIKE ? OR ${MediaStore.Downloads.DISPLAY_NAME} = ?)"
                val selectionArgs = arrayOf("Download/$FYONA_FOLDER%", "fyona_backup_%", "FYONA_ERP_Backup%.json", "FYONA_ERP_Backup.json")

                contentResolver.query(collection, projection, selection, selectionArgs, "${MediaStore.Downloads.DATE_MODIFIED} DESC")?.use { cursor ->
                    val idCol = cursor.getColumnIndexOrThrow(MediaStore.Downloads._ID)
                    val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Downloads.DISPLAY_NAME)
                    val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Downloads.SIZE)
                    val dateCol = cursor.getColumnIndexOrThrow(MediaStore.Downloads.DATE_MODIFIED)
                    val pathCol = cursor.getColumnIndexOrThrow(MediaStore.Downloads.RELATIVE_PATH)

                    while (cursor.moveToNext()) {
                        val id = cursor.getLong(idCol)
                        val name = cursor.getString(nameCol) ?: ""
                        val size = cursor.getLong(sizeCol)
                        val dateModified = cursor.getLong(dateCol)
                        val relPath = cursor.getString(pathCol) ?: ""
                        val uri = Uri.withAppendedPath(collection, id.toString())

                        backups.add(mapOf(
                            "uri" to uri.toString(),
                            "name" to name,
                            "size" to size,
                            "dateModified" to dateModified,
                            "relativePath" to relPath
                        ))
                    }
                }
            } else {
                val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), FYONA_FOLDER)
                if (dir.exists()) {
                    dir.listFiles()
                        ?.filter { it.isFile && (it.name.startsWith("FYONA_ERP_Backup") || it.name.startsWith("fyona_backup_")) && it.name.endsWith(".json") }
                        ?.sortedByDescending { it.lastModified() }
                        ?.forEach { f ->
                            backups.add(mapOf(
                                "uri" to Uri.fromFile(f).toString(),
                                "name" to f.name,
                                "size" to f.length(),
                                "dateModified" to (f.lastModified() / 1000L),
                                "relativePath" to "Download/$FYONA_FOLDER/"
                            ))
                        }
                }
            }

            // Direct File fallback for Q+ (MediaStore may hide previous install's files without permission).
            if (backups.isEmpty()) {
                try {
                    val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), FYONA_FOLDER)
                    if (dir.exists()) {
                        dir.listFiles()
                            ?.filter { it.isFile && it.name.startsWith("FYONA_ERP_Backup") && it.name.endsWith(".json") }
                            ?.sortedByDescending { it.lastModified() }
                            ?.forEach { f ->
                                if (backups.none { it["uri"] == Uri.fromFile(f).toString() }) {
                                    backups.add(mapOf(
                                        "uri" to Uri.fromFile(f).toString(),
                                        "name" to f.name,
                                        "size" to f.length(),
                                        "dateModified" to (f.lastModified() / 1000L),
                                        "relativePath" to "Download/$FYONA_FOLDER/"
                                    ))
                                }
                            }
                    }
                } catch (_: Exception) {}
            }

            // SAF fallback: بعد إعادة التثبيت، ملفات Download قد لا تظهر في MediaStore بدون صلاحية.
            // إذا كان لدى المستخدم Tree URI محفوظ، نحاول قراءة المجلد عبر SAF.
            if (backups.isEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val safBackups = listViaSafTree()
                if (safBackups.isNotEmpty()) {
                    backups.addAll(safBackups)
                    Log.i(TAG, "listBackups via SAF: ${safBackups.size} files")
                }
            }

            Log.i(TAG, "listBackups: ${backups.size} files under Download/$FYONA_FOLDER")
            result.success(mapOf("success" to true, "backups" to backups))
        } catch (e: Exception) {
            Log.e(TAG, "listBackups exception: ${e.message}")
            result.success(mapOf("success" to false, "message" to "خطأ: ${e.message}", "backups" to emptyList<Map<String, Any?>>()))
        }
    }

    private fun listViaSafTree(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        try {
            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val treeStr = prefs.getString("flutter.backup_saved_tree_uri", null) ?: return out
            if (treeStr.isEmpty()) return out
            val treeUri = Uri.parse(treeStr)
            // تحقق من بقاء الصلاحية
            val hasPersisted = contentResolver.persistedUriPermissions.any { it.uri == treeUri && it.isReadPermission }
            if (!hasPersisted) {
                Log.w(TAG, "SAF tree permission lost: $treeUri")
                return out
            }
            val docId = DocumentsContract.getTreeDocumentId(treeUri)
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED
            )
            contentResolver.query(childrenUri, projection, null, null, null)?.use { c ->
                val idCol = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameCol = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val sizeCol = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
                val modCol = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                while (c.moveToNext()) {
                    val docIdChild = c.getString(idCol) ?: continue
                    val name = c.getString(nameCol) ?: continue
                    if (!(name.startsWith("FYONA_ERP_Backup") || name.startsWith("fyona_backup_"))) continue
                    if (!name.endsWith(".json")) continue
                    val size = try { c.getLong(sizeCol) } catch (_: Exception) { 0L }
                    val lastMod = try { c.getLong(modCol) } catch (_: Exception) { 0L }
                    val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docIdChild)
                    out.add(mapOf(
                        "uri" to docUri.toString(),
                        "name" to name,
                        "size" to size,
                        "dateModified" to (lastMod / 1000L),
                        "relativePath" to "Download/$FYONA_FOLDER/"
                    ))
                }
            }
            out.sortByDescending { (it["dateModified"] as Long) }
        } catch (e: Exception) {
            Log.e(TAG, "listViaSafTree failed: ${e.message}")
        }
        return out
    }

    private fun requestStoragePermission(result: MethodChannel.Result) {
        val sdk = Build.VERSION.SDK_INT
        val perm = if (sdk >= Build.VERSION_CODES.TIRAMISU) android.Manifest.permission.READ_MEDIA_IMAGES else android.Manifest.permission.READ_EXTERNAL_STORAGE
        val alreadyGranted = checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        Log.i(TAG, "Permission check: SDK=$sdk perm=$perm granted=$alreadyGranted")

        if (sdk >= Build.VERSION_CODES.Q && alreadyGranted) {
            result.success(mapOf(
                "granted" to true,
                "needed" to false,
                "androidVersion" to sdk,
                "message" to "MediaStore لا يتطلب صلاحيات تخزين على هذا النظام"
            ))
            return
        }
        if (sdk >= Build.VERSION_CODES.Q) {
            // For discovering previous install's files in Download, READ is needed.
            pendingPermissionResult = result
            permissionLauncher.launch(arrayOf(perm))
            return
        }

        // API <= 28: WRITE_EXTERNAL_STORAGE is required for shared storage.
        if (alreadyGranted) {
            result.success(mapOf("granted" to true, "needed" to true, "androidVersion" to sdk))
            return
        }
        pendingPermissionResult = result
        permissionLauncher.launch(arrayOf(android.Manifest.permission.WRITE_EXTERNAL_STORAGE))
    }

    /** Saves arbitrary bytes (e.g. a PDF invoice) to Download/FYONA ERP with a
     *  verified write, returning the display path on success. */
    private fun saveBytesToDownloads(
        fileName: String,
        bytes: ByteArray?,
        mime: String,
        result: MethodChannel.Result,
    ) {
        if (bytes == null || bytes.isEmpty()) {
            result.success(mapOf("success" to false, "message" to "لا توجد بيانات"))
            return
        }
        val safeName = if (fileName.isBlank()) "invoice.pdf" else fileName
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                if (checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                    PackageManager.PERMISSION_GRANTED
                ) {
                    result.success(mapOf("success" to false, "message" to "صلاحية التخزين مطلوبة"))
                    return
                }
                val dir = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                    FYONA_FOLDER,
                )
                if (!dir.exists() && !dir.mkdirs()) {
                    result.success(mapOf("success" to false, "message" to "تعذر إنشاء المجلد"))
                    return
                }
                val target = File(dir, safeName)
                target.writeBytes(bytes)
                if (target.length() <= 0) {
                    result.success(mapOf("success" to false, "message" to "فشل التحقق من الكتابة"))
                    return
                }
                result.success(mapOf(
                    "success" to true,
                    "filePath" to "Download/$FYONA_FOLDER/$safeName",
                    "fileName" to safeName,
                    "fileSize" to target.length(),
                ))
                return
            }

            val resolver = contentResolver
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val relativePath = Environment.DIRECTORY_DOWNLOADS + "/$FYONA_FOLDER/"
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, safeName)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(collection, values)
            if (uri == null) {
                result.success(mapOf("success" to false, "message" to "فشل إنشاء الملف"))
                return
            }
            try {
                resolver.openOutputStream(uri)?.use { os ->
                    os.write(bytes)
                    os.flush()
                } ?: run {
                    deleteQuietly(uri)
                    result.success(mapOf("success" to false, "message" to "فشل فتح الملف للكتابة"))
                    return
                }
                resolver.update(
                    uri,
                    ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) },
                    null,
                    null,
                )
                val statSize = try {
                    resolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: 0L
                } catch (_: Exception) { 0L }
                if (statSize <= 0) {
                    deleteQuietly(uri)
                    result.success(mapOf("success" to false, "message" to "فشل التحقق من الكتابة"))
                    return
                }
                result.success(mapOf(
                    "success" to true,
                    "uri" to uri.toString(),
                    "filePath" to "Download/$FYONA_FOLDER/$safeName",
                    "fileName" to safeName,
                    "fileSize" to statSize,
                ))
            } catch (e: Exception) {
                deleteQuietly(uri)
                throw e
            }
        } catch (e: Exception) {
            Log.e(TAG, "saveBytesToDownloads exception: ${e.message}", e)
            result.success(mapOf("success" to false, "message" to "خطأ أثناء الحفظ: ${e.message}"))
        }
    }

    // ═════════════════════════════════════════════════════════════════
    // Business printing: Bluetooth ESC/POS (classic SPP)
    // ═════════════════════════════════════════════════════════════════
    private fun bluetoothAdapter(): BluetoothAdapter? = try {
        val mgr = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        mgr?.adapter
    } catch (_: Exception) {
        null
    }

    private fun btConnect(address: String, result: MethodChannel.Result) {
        if (address.isEmpty()) {
            result.error("args", "عنوان الطابعة مطلوب", null)
            return
        }
        Thread {
            try {
                val a = bluetoothAdapter()
                if (a == null) {
                    runOnUiThread { result.error("bt", "البلوتوث غير مدعوم على هذا الجهاز", null) }
                    return@Thread
                }
                @Suppress("MissingPermission")
                val dev: BluetoothDevice = a.getRemoteDevice(address)
                btDisconnect()
                @Suppress("MissingPermission")
                val socket = dev.createRfcommSocketToServiceRecord(btSppUuid)
                @Suppress("MissingPermission")
                socket.connect()
                btSocket = socket
                btOut = socket.outputStream
                runOnUiThread { result.success(true) }
            } catch (e: SecurityException) {
                runOnUiThread { result.error("permission", "صلاحية البلوتوث مطلوبة", null) }
            } catch (e: Exception) {
                runOnUiThread { result.error("connect", e.message ?: "فشل الاتصال بالطابعة", null) }
            }
        }.start()
    }

    private fun btWrite(bytes: ByteArray?, result: MethodChannel.Result) {
        if (bytes == null || bytes.isEmpty()) {
            result.error("args", "لا توجد بيانات للإرسال", null)
            return
        }
        Thread {
            try {
                val out = btOut
                if (out == null) {
                    runOnUiThread { result.error("state", "الطابعة غير متصلة", null) }
                    return@Thread
                }
                out.write(bytes)
                out.flush()
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                runOnUiThread { result.error("write", e.message ?: "فشل إرسال البيانات للطابعة", null) }
            }
        }.start()
    }

    private fun btDisconnect() {
        try { btOut?.close() } catch (_: Exception) {}
        try { btSocket?.close() } catch (_: Exception) {}
        btOut = null
        btSocket = null
    }
}

/**
 * BroadcastReceiver that fires when AlarmManager triggers.
 *
 * Generalized pipeline (kind = "debt" | "recurring"): ensures the right
 * channel exists natively (works even when the app is killed and
 * flutter_local_notifications never runs), then posts a normal
 * high-priority heads-up notification with sound_2.
 *
 * NO setFullScreenIntent, NO AlarmActivity launch. Tapping MainActivity
 * stores a payload Dart pulls via getInitialAlarmPayload.
 */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val rawKind = (intent.getStringExtra("kind") ?: "debt").lowercase()
        val kind = if (rawKind == "recurring") "recurring" else "debt"
        val title = intent.getStringExtra("title")
            ?: if (kind == "debt") "تنبيه استحقاق الدين" else "تذكير"
        val body = intent.getStringExtra("body")
            ?: if (kind == "debt") "لديك دين مستحق الآن" else ""
        // New alarms carry refId (+route); legacy debt alarms carry debtId.
        val refId = intent.getStringExtra("refId") ?: intent.getStringExtra("debtId") ?: ""
        val route = intent.getStringExtra("route") ?: ""
        // requestCode is the Dart-provided stable int (FNV) — used as-is for
        // both the content PendingIntent and the notification id, so cancel
        // matches. Legacy-only fallback (alarms scheduled without the extra).
        val requestCode = if (intent.hasExtra("requestCode")) {
            intent.getIntExtra("requestCode", 0)
        } else {
            0
        }.let { rc -> if (rc != 0) rc else (refId.hashCode() and 0x7fffffff) }

        val channelId = if (kind == "recurring") {
            ReminderAlarmScheduler.migrateStaleChannelsOnce(context)
            ReminderAlarmScheduler.ensureRecurringChannel(context)
            ReminderAlarmScheduler.RECURRING_CHANNEL_ID
        } else {
            ReminderAlarmScheduler.migrateStaleChannelsOnce(context)
            ReminderAlarmScheduler.ensureDebtChannel(context)
            ReminderAlarmScheduler.DEBT_CHANNEL_ID
        }

        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("fyona_notif_kind", kind)
            putExtra("fyona_notif_refId", refId)
            putExtra("fyona_notif_route", route)
            if (kind == "debt") {
                // Legacy extras so the current Dart debt flow keeps working.
                putExtra("alarm_debt_id", refId)
                putExtra("debtId", refId)
                putExtra("from_alarm", true)
            }
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            requestCode,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val soundUri = ReminderAlarmScheduler.soundUri(context)

        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(if (kind == "recurring") NotificationCompat.CATEGORY_REMINDER else NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setOngoing(false)
            .setSound(soundUri)
            .setVibrate(longArrayOf(0, 500, 200, 500, 200, 500))
            .setColor(0xFF000000.toInt())
            .build()

        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(requestCode, notification)
        } catch (_: Exception) {}
    }
}

/**
 * Re-schedules all pending alarms after device reboot — silently, without
 * launching UI. Re-arms BOTH stores:
 *  - flutter.debt_reminders_v2       entries debt_<id>  = {debt, millis, ...}
 *  - flutter.recurring_reminders_v2  entries recur_<id> = {millis, title,
 *    body, kind, refId, requestCode, route}
 * Stale entries (millis < now) are skipped AND dropped from prefs.
 * Reads the FlutterSharedPreferences file exactly as Dart writes it
 * (SharedPreferences JSON strings).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != "com.htc.intent.action.QUICKBOOT_POWERON"
        ) return
        try { rearmDebtStore(context) } catch (_: Exception) {}
        try { rearmRecurringStore(context) } catch (_: Exception) {}
    }

    private fun rearmDebtStore(context: Context) {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val raw = prefs.getString("flutter.debt_reminders_v2", null) ?: return
        if (raw.isEmpty() || raw == "{}") return
        val json = JSONObject(raw)
        val now = System.currentTimeMillis()
        val keys = mutableListOf<String>()
        val it = json.keys()
        while (it.hasNext()) { keys.add(it.next() as String) }
        var dropped = false
        for (key in keys) {
            val obj = json.optJSONObject(key) ?: continue
            val millis = obj.optLong("millis", 0L)
            if (millis == 0L || millis < now) {
                try { json.remove(key) } catch (_: Exception) {}
                dropped = true
                continue
            }
            // Prefer an explicit requestCode written by Dart (stable FNV int,
            // used as-is); fall back to the legacy derivation for old entries.
            val storedRc = obj.optLong("requestCode", 0L).toInt()
            val debtObj = obj.optJSONObject("debt") ?: continue
            val personName = debtObj.optString("person_name", "تنبيه الدين")
            val type = debtObj.optString("debt_type", "payable")
            val amount = debtObj.optDouble("amount", 0.0)
            val currency = debtObj.optString("currency", "SAR")
            val debtId = debtObj.optString("id", key.removePrefix("debt_"))
            val title = if (type == "payable") "حان موعد سداد الدين" else "حان موعد تحصيل الدين"
            val body = "$personName — $amount $currency"
            val requestCode = if (storedRc != 0) storedRc else (debtId.toIntOrNull() ?: debtId.hashCode().and(0x7fffffff))

            try {
                ReminderAlarmScheduler.scheduleExact(context, millis, title, body, "debt", debtId, requestCode, "")
            } catch (_: Exception) {}
        }
        if (dropped) {
            try { prefs.edit().putString("flutter.debt_reminders_v2", json.toString()).apply() } catch (_: Exception) {}
        }
    }

    private fun rearmRecurringStore(context: Context) {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val raw = prefs.getString("flutter.recurring_reminders_v2", null) ?: return
        if (raw.isEmpty() || raw == "{}") return
        val json = JSONObject(raw)
        val now = System.currentTimeMillis()
        val keys = mutableListOf<String>()
        val it = json.keys()
        while (it.hasNext()) { keys.add(it.next() as String) }
        var dropped = false
        for (key in keys) {
            val obj = json.optJSONObject(key) ?: continue
            val millis = obj.optLong("millis", 0L)
            if (millis == 0L || millis < now) {
                try { json.remove(key) } catch (_: Exception) {}
                dropped = true
                continue
            }
            val title = obj.optString("title", "تذكير")
            val body = obj.optString("body", "")
            val kind = obj.optString("kind", "recurring").lowercase()
            val safeKind = if (kind == "debt") "debt" else "recurring"
            val refId = obj.optString("refId", key.removePrefix("recur_"))
            // Dart-provided stable code, used as-is; legacy-only fallback.
            val storedRc = obj.optLong("requestCode", 0L).toInt()
            val requestCode = if (storedRc != 0) storedRc else (refId.hashCode() and 0x7fffffff)
            val route = obj.optString("route", "")
            try {
                ReminderAlarmScheduler.scheduleExact(context, millis, title, body, safeKind, refId, requestCode, route)
            } catch (_: Exception) {}
        }
        if (dropped) {
            try { prefs.edit().putString("flutter.recurring_reminders_v2", json.toString()).apply() } catch (_: Exception) {}
        }
    }
}


