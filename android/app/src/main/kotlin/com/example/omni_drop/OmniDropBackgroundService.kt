package com.example.omni_drop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class OmniDropBackgroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "OmniDrop background connection",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps OmniDrop available to receive transfers while in the background."
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val preferences = getSharedPreferences("omnidrop_runtime", MODE_PRIVATE)
        val savedTransferActive = preferences.getBoolean("transfer_notification_active", false)
        val title = intent?.getStringExtra(EXTRA_TITLE)
            ?: (if (savedTransferActive) preferences.getString("transfer_notification_title", "OmniDrop transfer")
                else "OmniDrop is available")
            ?: "OmniDrop is available"
        val text = intent?.getStringExtra(EXTRA_TEXT)
            ?: (if (savedTransferActive) preferences.getString("transfer_notification_text", "Transferring files")
                else "Ready to receive files from your paired devices.")
            ?: "Ready to receive files from your paired devices."
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, -1)?.takeIf { it >= 0 }
            ?: if (savedTransferActive) preferences.getInt("transfer_notification_progress", -1) else -1
        val active = if (intent?.hasExtra(EXTRA_ACTIVE) == true) {
            intent.getBooleanExtra(EXTRA_ACTIVE, true)
        } else {
            true
        }
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).setFlags(
                Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP,
            ),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openApp)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(active)
            .setAutoCancel(!active)
            .setShowWhen(false)
            .setProgress(100, progress.coerceIn(0, 100), progress < 0 && active)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        if (!active) {
            @Suppress("DEPRECATION")
            stopForeground(false)
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        getSharedPreferences("omnidrop_runtime", MODE_PRIVATE)
            .edit().putBoolean("transfer_notification_active", false).apply()
        @Suppress("DEPRECATION")
        stopForeground(true)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        @Suppress("DEPRECATION")
        stopForeground(true)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "omnidrop_background_connection"
        private const val NOTIFICATION_ID = 53679
        const val EXTRA_TITLE = "notification_title"
        const val EXTRA_TEXT = "notification_text"
        const val EXTRA_PROGRESS = "notification_progress"
        const val EXTRA_ACTIVE = "notification_active"
    }
}
