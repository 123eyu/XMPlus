package teikengstudio.xmplus

import android.Manifest
import android.app.NotificationManager
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
import android.content.Intent
import android.os.StatFs
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    private var notificationPermissionResult: MethodChannel.Result? = null
    private val notificationPermissionRequest = 2102

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "teikengstudio.xmplus/platform")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "mediaToolPaths" -> {
                            val directory = File(applicationInfo.nativeLibraryDir).canonicalFile
                            val paths = mutableMapOf("directory" to directory.path)
                            for (name in listOf("ffmpeg", "ffprobe")) {
                                val file = File(directory, "libxmplus_$name.so")
                                require(file.isAbsolute && file.canonicalFile == file &&
                                    file.parentFile == directory && file.isFile && file.canExecute()) {
                                    "Installed media executable is missing or invalid: $name"
                                }
                                paths[name] = file.path
                            }
                            result.success(paths)
                        }
                        "availableBytes" -> {
                            val path = requireNotNull(call.argument<String>("path"))
                            result.success(StatFs(File(path).canonicalPath).availableBytes)
                        }
                        "openAudioFile" -> {
                            val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                            require(file.isFile) { "Audio file does not exist" }
                            val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "audio/*")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(Intent.createChooser(intent, "打开音频"))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("android_platform", error.message, null)
                }
            }
        DownloadForegroundService.messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DownloadForegroundService.CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "downloadNotificationPermission" -> {
                            val enabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                                getSystemService(NotificationManager::class.java).areNotificationsEnabled()
                            } else true
                            if (enabled || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                                call.argument<Boolean>("request") != true) {
                                result.success(enabled)
                            } else if (notificationPermissionResult != null) {
                                result.error("permission_pending", "通知权限请求尚未结束", null)
                            } else {
                                notificationPermissionResult = result
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationPermissionRequest)
                            }
                        }
                        "downloadForeground" -> {
                            val intent = Intent(this, DownloadForegroundService::class.java).apply {
                                putExtra("title", requireNotNull(call.argument<String>("title")))
                                putExtra("text", requireNotNull(call.argument<String>("text")))
                                putExtra("receivedBytes", requireNotNull(call.argument<Number>("receivedBytes")).toLong())
                                putExtra("totalBytes", call.argument<Number>("totalBytes")?.toLong() ?: 0L)
                            }
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
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                                else startService(intent)
                            }
                        }
                        "stopDownloadForeground" -> {
                            val service = DownloadForegroundService.instance
                            if (service != null) {
                                service.stopPresenting { result.success(null) }
                            } else {
                                stopService(Intent(this, DownloadForegroundService::class.java))
                                result.success(null)
                            }
                        }
                        "batteryOptimizationExempt" -> result.success(
                            getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
                        )
                        "requestBatteryOptimizationExemption" -> {
                            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")))
                            result.success(null)
                        }
                        "showDownloadBackgroundError" -> {
                            Toast.makeText(applicationContext, call.argument<String>("message"), Toast.LENGTH_LONG).show()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    if (call.method == "downloadForeground") {
                        Toast.makeText(applicationContext, "下载后台服务启动失败，请保持应用在前台：${error.message}", Toast.LENGTH_LONG).show()
                    }
                    result.error("android_background", error.message, null)
                }
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationPermissionRequest) {
            notificationPermissionResult?.success(
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            )
            notificationPermissionResult = null
        }
    }

    override fun onDestroy() {
        notificationPermissionResult?.success(false)
        notificationPermissionResult = null
        super.onDestroy()
    }
}
