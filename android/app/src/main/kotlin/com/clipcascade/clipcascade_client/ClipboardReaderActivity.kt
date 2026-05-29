package com.clipcascade.clipcascade_client

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Invisible activity that gains focus to read clipboard on Android 10+.
 * Waits for window focus before reading, then finishes immediately.
 */
class ClipboardReaderActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d("ClipCascade", "ReaderActivity created")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            Log.d("ClipCascade", "ReaderActivity got focus")
            readClipboard()
            finish()
            overridePendingTransition(0, 0)
        }
    }

    private fun readClipboard() {
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = cm.primaryClip
            if (clip != null && clip.itemCount > 0) {
                val text = clip.getItemAt(0).coerceToText(this)?.toString()
                if (!text.isNullOrEmpty()) {
                    val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    prefs.edit()
                        .putString("flutter.clip_content", text)
                        .putLong("flutter.clip_ts", System.currentTimeMillis())
                        .apply()
                    Log.d("ClipCascade", "Overlay captured: ${text.length} chars")
                } else {
                    Log.d("ClipCascade", "Overlay: empty text")
                }
            } else {
                Log.d("ClipCascade", "Overlay: no clip data")
            }
        } catch (e: Exception) {
            Log.e("ClipCascade", "Overlay failed: ${e.message}")
        }
    }
}
