package teikengstudio.xmplus

import android.content.Intent
import android.os.StatFs
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
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
    }
}
