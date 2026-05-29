package com.clipcascade.clipcascade_client

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.PixelFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.View
import android.view.ViewTreeObserver
import android.view.WindowManager
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
    private val handler = Handler(Looper.getMainLooper())

    companion object {
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
                "requestBatteryExemption" -> {
                    try {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
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

        // 1) Standard clipboard listener (works in foreground)
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
                                    Log.d("ClipCascade", "Logcat detected clipboard change")
                                    handler.post { readClipboardViaOverlay() }
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

    private fun readClipboardViaOverlay() {
        if (!Settings.canDrawOverlays(this)) {
            Log.d("ClipCascade", "No overlay permission, cannot read clipboard in background")
            return
        }

        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val overlayView = View(this)

        val params = WindowManager.LayoutParams(
            1, 1,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply { x = 0; y = 0 }

        try {
            wm.addView(overlayView, params)

            // Make focusable to gain clipboard access
            params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
            wm.updateViewLayout(overlayView, params)

            // Read clipboard once layout is done
            overlayView.viewTreeObserver.addOnGlobalLayoutListener(object : ViewTreeObserver.OnGlobalLayoutListener {
                override fun onGlobalLayout() {
                    overlayView.viewTreeObserver.removeOnGlobalLayoutListener(this)
                    try {
                        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val clip = cm.primaryClip
                        if (clip != null && clip.itemCount > 0) {
                            val text = clip.getItemAt(0).coerceToText(applicationContext)?.toString()
                            if (!text.isNullOrEmpty()) {
                                val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                                prefs.edit()
                                    .putString("flutter.clip_content", text)
                                    .putLong("flutter.clip_ts", System.currentTimeMillis())
                                    .apply()
                                Log.d("ClipCascade", "Overlay captured: ${text.length} chars")
                            }
                        }
                    } catch (e: Exception) {
                        Log.e("ClipCascade", "Overlay read failed: ${e.message}")
                    } finally {
                        // Remove overlay and make non-focusable again
                        try { wm.removeViewImmediate(overlayView) } catch (_: Exception) {}
                    }
                }
            })
        } catch (e: Exception) {
            Log.e("ClipCascade", "Overlay creation failed: ${e.message}")
            try { wm.removeViewImmediate(overlayView) } catch (_: Exception) {}
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
