package com.clipcascade.clipcascade_client

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.util.Log

/**
 * Transparent activity that briefly gains focus to read the clipboard
 * on Android 10+, then finishes immediately.
 * The activity itself gaining focus is enough to read clipboard.
 */
class ClipboardReaderActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        readClipboard()
        finish()
        overridePendingTransition(0, 0)
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
                }
            }
        } catch (e: Exception) {
            Log.e("ClipCascade", "Overlay read failed: ${e.message}")
        }
    }
}
