package com.clipcascade.clipcascade_client

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.clipcascade/clipboard"

    companion object {
        // Static so it survives activity recreation and runs in the app process
        private var logcatThread: Thread? = null
        private var logcatProcess: Process? = null
        private var stopLogcat = false
        private var clipListener: ClipboardManager.OnPrimaryClipChangedListener? = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
        startClipboardMonitoring()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasOverlayPermission" -> result.success(Settings.canDrawOverlays(this))
                "requestOverlayPermission" -> {
                    startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION))
                    result.success(null)
                }
                "openBatterySettings" -> {
                    // Try Honor/Huawei specific settings first
                    val intents = listOf(
                        Intent().setClassName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
                        Intent().setClassName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
                        Intent().setClassName("com.hihonor.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
                        Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    )
                    for (intent in intents) {
                        try {
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                            return@setMethodCallHandler
                        } catch (_: Exception) {}
                    }
                    result.success(false)
                }
                "requestBatteryExemption" -> {
                    try {
                        val intent = Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                        intent.data = android.net.Uri.parse("package:$packageName")
                        startActivity(intent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "clipcascade_sync",
                "ClipCascade Sync",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps clipboard sync running in the background"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun startClipboardMonitoring() {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

        // 1) Standard clipboard listener
        if (clipListener == null) {
            clipListener = ClipboardManager.OnPrimaryClipChangedListener {
                readAndStore(cm)
            }
            cm.addPrimaryClipChangedListener(clipListener)
            Log.d("ClipCascade", "Clipboard listener registered")
        }

        // 2) Logcat monitoring (Android 10+ with READ_LOGS)
        if (logcatThread == null &&
            Build.VERSION.SDK_INT > Build.VERSION_CODES.P &&
            ContextCompat.checkSelfPermission(this, android.Manifest.permission.READ_LOGS) == PackageManager.PERMISSION_GRANTED
        ) {
            stopLogcat = false
            logcatThread = Thread {
                try {
                    val timeStamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.getDefault())
                        .format(Date())
                    logcatProcess = Runtime.getRuntime().exec(
                        arrayOf("logcat", "-T", timeStamp, "ClipboardService:E", "*:S")
                    )
                    Log.d("ClipCascade", "Logcat monitoring started")
                    val reader = BufferedReader(InputStreamReader(logcatProcess!!.inputStream))
                    var lastTime: Long = 0
                    reader.use { br ->
                        var line: String? = null
                        while (!stopLogcat && br.readLine().also { line = it } != null) {
                            if (line!!.contains(packageName)) {
                                val now = System.currentTimeMillis()
                                if (now - lastTime > 1000) {
                                    lastTime = now
                                    Log.d("ClipCascade", "Logcat detected clipboard change, launching reader")
                                    val intent = Intent(applicationContext, ClipboardReaderActivity::class.java)
                                    intent.addFlags(
                                        Intent.FLAG_ACTIVITY_NEW_TASK or
                                        Intent.FLAG_ACTIVITY_CLEAR_TASK or
                                        Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS
                                    )
                                    startActivity(intent)
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.e("ClipCascade", "Logcat error: ${e.message}")
                } finally {
                    try { logcatProcess?.destroy() } catch (_: Exception) {}
                    logcatThread = null
                }
            }.apply {
                isDaemon = true
                start()
            }
        } else {
            Log.d("ClipCascade", "READ_LOGS not granted or Android <= 9")
        }
    }

    private fun readAndStore(cm: ClipboardManager) {
        try {
            val clip = cm.primaryClip
            if (clip != null && clip.itemCount > 0) {
                val text = clip.getItemAt(0).coerceToText(this)?.toString()
                if (!text.isNullOrEmpty()) {
                    val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    prefs.edit()
                        .putString("flutter.clip_content", text)
                        .putLong("flutter.clip_ts", System.currentTimeMillis())
                        .apply()
                    Log.d("ClipCascade", "Clipboard captured: ${text.length} chars")
                }
            }
        } catch (e: Exception) {
            Log.d("ClipCascade", "Read failed: ${e.message}")
        }
    }
}
