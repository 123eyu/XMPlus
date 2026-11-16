package teikengstudio.xmplus.background

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.ResultReceiver
import android.provider.Settings
import android.widget.Toast
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** Engine-owned commands remain available while audio_service has no Activity. */
class DownloadBackgroundPlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private lateinit var messenger: BinaryMessenger
    private lateinit var channel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null
    private var notificationPermissionResult: MethodChannel.Result? = null
    private val notificationPermissionRequest = 2102

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        messenger = binding.binaryMessenger
        channel = MethodChannel(messenger, DownloadForegroundService.CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        detachActivity()
        if (DownloadForegroundService.messenger === messenger) {
            DownloadForegroundService.messenger = null
            // The engine owns the workers: no engine means no work to advertise.
            context.stopService(Intent(context, DownloadForegroundService::class.java))
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        notificationPermissionResult?.success(false)
        notificationPermissionResult = null
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != notificationPermissionRequest) return false
        notificationPermissionResult?.success(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        )
        notificationPermissionResult = null
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "downloadNotificationPermission" -> {
                    val enabled = context.getSystemService(NotificationManager::class.java).areNotificationsEnabled()
                    val activity = activityBinding?.activity
                    if (enabled || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                        call.argument<Boolean>("request") != true || activity == null) {
                        result.success(enabled)
                    } else if (notificationPermissionResult != null) {
                        result.error("permission_pending", "通知权限请求尚未结束", null)
                    } else {
                        notificationPermissionResult = result
                        try {
                            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationPermissionRequest)
                        } catch (error: Exception) {
                            notificationPermissionResult = null
                            throw error
                        }
                    }
                }
                "downloadForeground" -> {
                    val intent = Intent(context, DownloadForegroundService::class.java).apply {
                        putExtra("title", requireNotNull(call.argument<String>("title")))
                        putExtra("text", requireNotNull(call.argument<String>("text")))
                        putExtra("receivedBytes", requireNotNull(call.argument<Number>("receivedBytes")).toLong())
                        putExtra("totalBytes", call.argument<Number>("totalBytes")?.toLong() ?: 0L)
                    }
                    DownloadForegroundService.messenger = messenger
                    val service = DownloadForegroundService.instance
                    if (service != null) {
                        service.update(intent)
                        result.success(null)
                    } else {
                        intent.putExtra("reply", object : ResultReceiver(Handler(Looper.getMainLooper())) {
                            override fun onReceiveResult(code: Int, data: Bundle?) {
                                if (code == 0) result.success(null)
                                else result.error("download_foreground", data?.getString("error"), null)
                            }
                        })
                        context.startForegroundService(intent)
                    }
                }
                "stopDownloadForeground" -> {
                    val owner = DownloadForegroundService.messenger
                    if (owner != null && owner !== messenger) {
                        result.success(null)
                        return
                    }
                    val service = DownloadForegroundService.instance
                    if (service != null) {
                        service.stopPresenting { result.success(null) }
                    } else {
                        context.stopService(Intent(context, DownloadForegroundService::class.java))
                        result.success(null)
                    }
                    // Clear now, not in onDestroy: another engine may start before that callback.
                    DownloadForegroundService.messenger = null
                }
                "batteryOptimizationExempt" -> result.success(
                    context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)
                )
                "requestBatteryOptimizationExemption" -> {
                    val activity = checkNotNull(activityBinding?.activity) { "Activity is not attached" }
                    activity.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:${context.packageName}")))
                    result.success(null)
                }
                "showDownloadBackgroundError" -> {
                    Toast.makeText(context, call.argument<String>("message"), Toast.LENGTH_LONG).show()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            if (call.method == "downloadForeground") {
                Toast.makeText(context, "下载后台服务启动失败，请保持应用在前台：${error.message}", Toast.LENGTH_LONG).show()
            }
            result.error("android_background", error.message, null)
        }
    }
}
