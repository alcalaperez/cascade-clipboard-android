package com.clipcascade.clipcascade_client

import android.app.Service
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.BufferedReader
import java.io.InputStreamReader
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class ClipboardListenerService : Service() {
    private var clipboardManager: ClipboardManager? = null
    private val handler = Handler(Looper.getMainLooper())
    private var isListening = false

    // Logcat monitoring
    private var stopLogcat = false
    private var logcatThread: Thread? = null
    private var logcatProcess: Process? = null
    private var lastActivityStartTime: Long = 0
    private val activityDebounceTime: Long = 1000

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        handler.postDelayed({ readClipboard() }, 100)
    }

    override fun onCreate() {
        super.onCreate()
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        startListening()
        Log.d("ClipCascade", "ClipboardListenerService started")
    }

    override fun onDestroy() {
        stopListening()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    private fun startListening() {
        if (isListening) return

        // 1) Standard clipboard listener (works in foreground)
        clipboardManager?.addPrimaryClipChangedListener(clipListener)
        isListening = true

        // 2) Logcat monitoring for background clipboard detection (Android 10+)
        if (Build.VERSION.SDK_INT > Build.VERSION_CODES.P &&
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
                    val reader = BufferedReader(InputStreamReader(logcatProcess!!.inputStream))
                    reader.use { br ->
                        var line: String? = null
                        while (!stopLogcat && br.readLine().also { line = it } != null) {
                            if (line!!.contains(packageName)) {
                                val currentTime = System.currentTimeMillis()
                                if (currentTime - lastActivityStartTime > activityDebounceTime) {
                                    lastActivityStartTime = currentTime
                                    // Launch overlay to gain focus and read clipboard
                                    val intent = Intent(this, ClipboardReaderActivity::class.java)
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
                    Log.e("ClipCascade", "Logcat monitoring error: ${e.message}")
                } finally {
                    try { logcatProcess?.destroy() } catch (_: Exception) {}
                }
            }.apply {
                isDaemon = true
                start()
            }
            Log.d("ClipCascade", "Logcat monitoring started (READ_LOGS granted)")
        } else {
            Log.d("ClipCascade", "READ_LOGS not granted, background clipboard detection limited")
        }
    }

    private fun stopListening() {
        clipboardManager?.removePrimaryClipChangedListener(clipListener)
        isListening = false
        stopLogcat = true
        try { logcatThread?.interrupt() } catch (_: Exception) {}
        try { logcatProcess?.destroy() } catch (_: Exception) {}
        logcatThread = null
        logcatProcess = null
    }

    private fun readClipboard() {
        try {
            val clip = clipboardManager?.primaryClip
            if (clip != null && clip.itemCount > 0) {
                val text = clip.getItemAt(0).coerceToText(this)?.toString()
                if (!text.isNullOrEmpty()) {
                    writeToPrefs(text)
                    return
                }
            }
        } catch (e: Exception) {
            Log.d("ClipCascade", "Direct read failed: $e")
        }
    }

    private fun writeToPrefs(text: String) {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        prefs.edit()
            .putString("flutter.clip_content", text)
            .putLong("flutter.clip_ts", System.currentTimeMillis())
            .apply()
        Log.d("ClipCascade", "Clipboard captured: ${text.length} chars")
    }
}
