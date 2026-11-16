package teikengstudio.xmplus

import android.net.Uri
import android.provider.Settings
import android.provider.DocumentsContract
import android.content.ClipData
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
import java.io.EOFException
import java.io.FileInputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : AudioServiceActivity() {
    private val logExportRequest = 2103
    private var pendingLogExport: LogExport? = null
    private val updatePermissionRequest = 2104
    private var pendingUpdate: Pair<File, MethodChannel.Result>? = null

    private class LogExport(
        val result: MethodChannel.Result,
        val sourcePath: String?,
        val length: Long,
        val tailPath: String?,
        val warningPrefix: ByteArray
    ) {
        val cancelled = AtomicBoolean(false)
    }

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
                            val path = requireNotNull(call.argument<String>("path"))
                            val requested = Uri.parse(path)
                            val uri = if (requested.scheme == "content") {
                                requested
                            } else {
                                val file = (if (requested.scheme == "file") File(requireNotNull(requested.path)) else File(path)).canonicalFile
                                require(file.isFile && file.canRead()) { "Audio file does not exist or is not readable" }
                                try {
                                    FileProvider.getUriForFile(this, "$packageName.files", file)
                                } catch (_: IllegalArgumentException) {
                                    SharedAudioProvider.uriForFile(this, file)
                                }
                            }
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "audio/*")
                                clipData = ClipData.newRawUri("audio", uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(Intent.createChooser(intent, "打开音频"))
                            result.success(null)
                        }
                        "installUpdate" -> {
                            check(pendingUpdate == null) { "安装授权尚未结束" }
                            val requested = File(requireNotNull(call.argument<String>("path")))
                            require(requested.isAbsolute) { "安装包路径无效" }
                            val file = requested.canonicalFile
                            val root = File(filesDir, "updates").canonicalFile
                            require(file.parentFile == root && file.isFile &&
                                file.name.matches(Regex("XMPlus-[0-9]+\\.[0-9]+\\.[0-9]+-android-(arm64-v8a|armeabi-v7a|x86_64)\\.apk"))) {
                                "安装包无效，请重新下载"
                            }
                            if (packageManager.canRequestPackageInstalls()) {
                                openUpdateInstaller(file)
                                result.success(null)
                            } else {
                                pendingUpdate = Pair(file, result)
                                try {
                                    startActivityForResult(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:$packageName")), updatePermissionRequest)
                                } catch (error: Exception) {
                                    pendingUpdate = null
                                    throw error
                                }
                            }
                        }
                        "claimLogUploadPrompt" -> result.success(XMPlusApplication.claimLogUploadPrompt())
                        "exportLogSnapshot" -> {
                            if (pendingLogExport != null) {
                                result.error("log_export_pending", "日志导出尚未结束", null)
                            } else {
                                val sourcePath = call.argument<String>("sourcePath")
                                val tailPath = call.argument<String>("tailPath")
                                val lengthValue = requireNotNull(call.argument<Number>("length"))
                                require(lengthValue is Int || lengthValue is Long) { "Invalid snapshot length" }
                                val length = lengthValue.toLong()
                                require(length >= 0 && (sourcePath != null || length == 0L))
                                sourcePath?.let { require(length <= checkedLogFile(it, false).length()) }
                                tailPath?.let { checkedLogFile(it, true) }
                                val fileName = requireNotNull(call.argument<String>("fileName"))
                                require(fileName.matches(Regex("XMPlus-[A-Za-z0-9_-]+\\.log"))) { "Invalid log filename" }
                                val warning = (call.argument<String>("warningPrefix") ?: "").toByteArray(Charsets.UTF_8)
                                require(warning.size <= 64 * 1024) { "Log warning exceeds 64 KiB" }
                                val pending = LogExport(result, sourcePath, length, tailPath, warning)
                                pendingLogExport = pending
                                try {
                                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                        addCategory(Intent.CATEGORY_OPENABLE)
                                        type = "text/plain"
                                        putExtra(Intent.EXTRA_TITLE, fileName)
                                    }, logExportRequest)
                                } catch (error: Exception) {
                                    pendingLogExport = null
                                    throw error
                                }
                            }
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
    }

    private fun openUpdateInstaller(file: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
        startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
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

    /** Only app-owned ordinary files directly below the two fixed roots. */
    private fun checkedLogFile(path: String, tail: Boolean): File {
        val directory = if (tail) cacheDir else File(filesDir, "logs")
        require(OsConstants.S_ISDIR(Os.lstat(directory.path).st_mode)) { "Invalid log directory" }
        val file = File(path)
        require(file.isAbsolute &&
            (file.parentFile == directory.absoluteFile || file.parentFile == directory.canonicalFile) &&
            file.canonicalFile == File(directory.canonicalFile, file.name)) { "Log path is outside its allowed directory" }
        require(OsConstants.S_ISREG(Os.lstat(file.path).st_mode)) { "Log path must be an ordinary file, not a link" }
        if (tail) {
            require(file.name.matches(Regex("xmplus-log-export-[A-Za-z0-9_-]+\\.tmp"))) { "Invalid log tail filename" }
            require(file.length() <= 1024 * 1024 + 64 * 1024) { "Log tail exceeds its bounded size" }
        } else {
            require(file.name.matches(Regex("XMPlus-[A-Za-z0-9_-]+\\.log"))) { "Invalid source log filename" }
        }
        return file
    }

    private fun copyLogFile(path: String, tail: Boolean, length: Long?, output: OutputStream,
                            buffer: ByteArray, pending: LogExport) {
        val file = checkedLogFile(path, tail)
        val fd = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
        try {
            FileInputStream(fd).use { input ->
                val stat = Os.fstat(fd)
                require(OsConstants.S_ISREG(stat.st_mode)) { "Log source is not a regular file" }
                val count = length ?: stat.st_size
                require(count >= 0 && count <= stat.st_size) { "Log snapshot length exceeds source" }
                if (tail) require(count <= 1024 * 1024 + 64 * 1024)
                var remaining = count
                while (remaining > 0) {
                    check(!pending.cancelled.get()) { "Log export cancelled" }
                    val read = input.read(buffer, 0, minOf(remaining, buffer.size.toLong()).toInt())
                    if (read < 0) throw EOFException("Log snapshot source was truncated")
                    if (read == 0) continue
                    output.write(buffer, 0, read)
                    remaining -= read
                }
            }
        } finally {
            // Android's FileInputStream(FileDescriptor) does not own the fd.
            if (fd.valid()) Os.close(fd)
        }
    }

    private fun deleteIncompleteLog(uri: Uri) {
        try {
            DocumentsContract.deleteDocument(contentResolver, uri)
        } catch (_: Exception) {
            // Some providers cannot delete; never touch the source session log.
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == updatePermissionRequest) {
            val pending = pendingUpdate
            pendingUpdate = null
            if (pending != null) {
                try {
                    check(packageManager.canRequestPackageInstalls()) { "未允许安装，请授权后重试" }
                    openUpdateInstaller(pending.first)
                    pending.second.success(null)
                } catch (error: Exception) {
                    pending.second.error("update_install", error.message, null)
                }
            }
            return
        }
        if (requestCode != logExportRequest) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val pending = pendingLogExport
        val uri = data?.data
        if (pending == null) {
            if (resultCode == RESULT_OK && uri != null) Thread { deleteIncompleteLog(uri) }.start()
            return
        }
        if (resultCode != RESULT_OK) {
            pendingLogExport = null
            pending.result.success(null)
            return
        }
        if (uri == null || uri.scheme != "content") {
            pendingLogExport = null
            pending.result.error("log_export", "文档提供方未返回有效的 content URI", null)
            return
        }
        Thread {
            var failure: Exception? = null
            try {
                check(!pending.cancelled.get()) { "Log export cancelled" }
                requireNotNull(contentResolver.openOutputStream(uri, "wt")) { "Cannot open document output" }.use { output ->
                    val buffer = ByteArray(64 * 1024)
                    output.write(pending.warningPrefix)
                    pending.sourcePath?.let { copyLogFile(it, false, pending.length, output, buffer, pending) }
                    pending.tailPath?.let { copyLogFile(it, true, null, output, buffer, pending) }
                    check(!pending.cancelled.get()) { "Log export cancelled" }
                    output.flush()
                }
            } catch (error: Exception) {
                failure = error
            }
            if (failure != null || pending.cancelled.get()) deleteIncompleteLog(uri)
            val error = failure
            runOnUiThread {
                if (pendingLogExport === pending) {
                    pendingLogExport = null
                    if (error == null && !pending.cancelled.get()) pending.result.success(uri.toString())
                    else pending.result.error("log_export", error?.message ?: "日志导出已取消", null)
                } else {
                    Thread { deleteIncompleteLog(uri) }.start()
                }
            }
        }.start()
    }

    override fun onDestroy() {
        pendingUpdate?.second?.error("update_install", "安装授权已中断，请重试", null)
        pendingUpdate = null
        pendingLogExport?.let {
            it.cancelled.set(true)
            it.result.error("log_export_destroyed", "Activity 已销毁，日志导出未完成", null)
        }
        pendingLogExport = null
        super.onDestroy()
    }
}
