package teikengstudio.xmplus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.ResultReceiver
import android.widget.Toast
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Presents the existing Dart download workers; never starts or restores a download. */
class DownloadForegroundService : Service() {
    companion object {
        const val CHANNEL = "teikengstudio.xmplus/download_background"
        private const val NOTIFICATION_CHANNEL = "teikengstudio.xmplus.downloads"
        private const val NOTIFICATION_ID = 2102
        var messenger: BinaryMessenger? = null
        var instance: DownloadForegroundService? = null
            private set
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null
    private var onStopped: (() -> Unit)? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(NOTIFICATION_CHANNEL, "下载进度", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "仅在下载或处理文件时显示进度"
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                }
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // No sticky restart: without Dart workers there is no work to advertise.
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        @Suppress("DEPRECATION")
        val reply = intent.getParcelableExtra<ResultReceiver>("reply")
        instance = this
        try {
            val notification = notification(intent)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            if (wakeLock == null) {
                wakeLock = getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:downloads")
                    .apply { acquire() }
            }
            reply?.send(0, Bundle.EMPTY)
        } catch (error: Exception) {
            val message = "下载后台服务启动失败：${error.message ?: error.javaClass.simpleName}；请保持应用在前台"
            Toast.makeText(applicationContext, message, Toast.LENGTH_LONG).show()
            reply?.send(1, Bundle().apply { putString("error", message) })
            stopPresenting {}
        }
        return START_NOT_STICKY
    }

    fun update(intent: Intent) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(intent))
    }

    fun stopPresenting(onStopped: () -> Unit) {
        this.onStopped = onStopped
        if (instance === this) instance = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        releaseWakeLock()
        stopSelf()
    }

    private fun notification(intent: Intent): Notification {
        val openApp = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val total = intent.getLongExtra("totalBytes", 0)
        val received = intent.getLongExtra("receivedBytes", 0).coerceAtLeast(0)
        val determinate = total > 0
        val progress = if (determinate) ((received.toDouble() / total) * 1000).toInt().coerceIn(0, 1000) else 0
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_download_notification)
            .setContentTitle(intent.getStringExtra("title") ?: "正在下载")
            .setContentText(intent.getStringExtra("text") ?: "")
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSound(null)
            .setVibrate(longArrayOf(0))
            .setDefaults(0)
            .setPriority(Notification.PRIORITY_LOW)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setProgress(1000, progress, !determinate)
            .build()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15+ dataSync has a shared six-hour/24h budget. Stop immediately;
        // ask the actual Dart owner to pause, never launch a replacement service.
        stopPresenting {}
        Toast.makeText(applicationContext, "系统后台下载时限已到，下载已暂停，请返回应用后手动继续", Toast.LENGTH_LONG).show()
        Handler(Looper.getMainLooper()).post {
            messenger?.let { MethodChannel(it, CHANNEL).invokeMethod("downloadServiceTimeout", null) }
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
        onStopped?.invoke()
        onStopped = null
    }
}
