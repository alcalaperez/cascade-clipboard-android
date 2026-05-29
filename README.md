# ClipCascade Flutter Client

A Flutter Android client for [ClipCascade](https://github.com/Sathvik-Rao/ClipCascade) — syncs your clipboard across devices in real-time via a self-hosted server.

## Features

- Real-time clipboard sync via STOMP/WebSocket
- Background clipboard monitoring (requires ADB setup)
- End-to-end AES-256-GCM encryption (optional)
- Foreground service with persistent notification
- Auto-reconnect with exponential backoff

## Setup

### 1. Build & Install

```bash
flutter build apk --release
adb install build/app/outputs/flutter-apk/app-release.apk
```

### 2. Grant Permissions (required for background clipboard monitoring)

```bash
adb shell pm grant com.clipcascade.clipcascade_client android.permission.READ_LOGS
```

After granting, force stop and reopen the app:

```bash
adb shell am force-stop com.clipcascade.clipcascade_client
```

### 3. Login

- **Server URL**: Your ClipCascade server address (e.g., `https://cascade.example.com`)
- **Username / Password**: Your ClipCascade credentials
- **Enable encryption**: Check this if your other devices have encryption enabled. The salt must match across all clients (leave empty if not set on other devices).

### 4. Start Sync

Tap "Start Sync" on the status screen. The foreground notification will appear and clipboard sync begins.

## How It Works

| Direction | Mechanism |
|-----------|-----------|
| **Receive** | STOMP subscription to `/user/queue/cliptext` — incoming clipboard is set locally |
| **Send (foreground)** | Polls clipboard every 1 second while app is visible |
| **Send (background)** | Native `ClipboardManager` listener + logcat monitoring detects clipboard changes, overlay window reads content, background service sends via STOMP |

## Encryption

When enabled, clipboard content is encrypted with AES-256-GCM before sending:

- **Key derivation**: PBKDF2-SHA256, 664,937 rounds, 32-byte output
- **Salt**: `username + password + user_salt`
- **Message format**: `{"nonce": "<base64>", "ciphertext": "<base64>", "tag": "<base64>"}`
- **Nonce**: 16 bytes random

All clients must use the same password, salt, and hash rounds to encrypt/decrypt successfully.

## Permissions

| Permission | Purpose |
|------------|---------|
| `INTERNET` | WebSocket connection to server |
| `FOREGROUND_SERVICE` | Keep sync running in background |
| `POST_NOTIFICATIONS` | Foreground service notification |
| `WAKE_LOCK` | Prevent service from sleeping |
| `READ_LOGS` | Detect clipboard changes in background (Android 10+) |
| `SYSTEM_ALERT_WINDOW` | Overlay to read clipboard when app is not focused |

## Requirements

- Android 10+ (API 29+)
- ClipCascade server (self-hosted)
- ADB access for initial permission setup

## Troubleshooting

- **Not sending in background**: Ensure `READ_LOGS` and `SYSTEM_ALERT_WINDOW` are granted via ADB, then restart the app.
- **Encryption errors (MAC check failed)**: Verify the salt and password match exactly across all clients.
- **Connection drops**: The app auto-reconnects with exponential backoff. Check server availability.
- **Battery optimization**: Disable battery optimization for ClipCascade in Android settings to prevent the OS from killing the service.
