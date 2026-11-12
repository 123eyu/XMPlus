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
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.io.FileDescriptor

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
        // Keep UI methods on the main queue; FUSE fallback copies can be large.
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "teikengstudio.xmplus/files", StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue())
            .setMethodCallHandler { call, result ->
                if (call.method != "copyNoReplace") {
                    result.notImplemented()
                } else {
                    try {
                        copyNoReplace(
                            requireNotNull(call.argument<String>("source")),
                            requireNotNull(call.argument<String>("target"))
                        )
                        result.success(null)
                    } catch (error: ErrnoException) {
                        val code = when (error.errno) {
                            OsConstants.EEXIST -> "destination_exists"
                            OsConstants.EXDEV -> "atomic_commit_cross_device"
                            OsConstants.ENOSYS, OsConstants.EINVAL, OsConstants.EOPNOTSUPP -> "atomic_commit_unsupported"
                            OsConstants.EPERM, OsConstants.EACCES -> "download_not_writable"
                            OsConstants.ENOSPC, OsConstants.EDQUOT -> "disk_space"
                            else -> "atomic_commit"
                        }
                        result.error(code, "文件安全提交失败，源缓存已保留（errno=${error.errno}）", null)
                    } catch (error: Exception) {
                        result.error("atomic_commit", "文件安全提交失败，源缓存已保留：${error.message}", null)
                    }
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

    private fun copyNoReplace(source: String, target: String) {
        require(File(source).isAbsolute && File(target).isAbsolute && source != target)
        var input: FileDescriptor? = null
        var output: FileDescriptor? = null
        var created: StructStat? = null
        var committed = false
        try {
            val sourceFd = Os.open(source, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
            input = sourceFd
            val sourceStat = Os.fstat(sourceFd)
            require(OsConstants.S_ISREG(sourceStat.st_mode)) { "Source must be a regular file" }
            val parent = requireNotNull(File(target).parentFile).canonicalFile
            if (sourceStat.st_dev != Os.stat(parent.path).st_dev) {
                throw ErrnoException("copyNoReplace", OsConstants.EXDEV)
            }
            // Recheck the actual output size; the earlier reserve is an estimate.
            if (StatFs(parent.path).availableBytes < sourceStat.st_size) {
                throw ErrnoException("copyNoReplace", OsConstants.ENOSPC)
            }
            val targetFd = Os.open(
                target,
                OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_NOFOLLOW,
                384 // 0600; never reopen the path after exclusive creation.
            )
            output = targetFd
            created = Os.fstat(targetFd)
            if (sourceStat.st_dev != created.st_dev) {
                throw ErrnoException("copyNoReplace", OsConstants.EXDEV)
            }
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = Os.read(sourceFd, buffer, 0, buffer.size)
                if (count == 0) break
                var offset = 0
                while (offset < count) {
                    val written = Os.write(targetFd, buffer, offset, count - offset)
                    if (written <= 0) throw ErrnoException("write", OsConstants.EIO)
                    offset += written
                }
            }
            Os.fsync(targetFd)
            // Do not retry close after an error: the fd may already be released.
            output = null
            Os.close(targetFd)
            input = null
            Os.close(sourceFd)
            committed = true
            try {
                val current = Os.lstat(source)
                if (current.st_dev == sourceStat.st_dev && current.st_ino == sourceStat.st_ino) {
                    Os.remove(source)
                }
            } catch (_: Exception) {
                // The destination is durable; leaving the temporary source is safe.
            }
        } finally {
            try { output?.let { Os.close(it) } } catch (_: Exception) { }
            try { input?.let { Os.close(it) } } catch (_: Exception) { }
            if (!committed) {
                created?.let { owned ->
                    try {
                        val current = Os.lstat(target)
                        if (current.st_dev == owned.st_dev && current.st_ino == owned.st_ino) {
                            Os.remove(target)
                        }
                    } catch (_: Exception) {
                        // Best effort only; never remove a replacement at this path.
                    }
                }
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
