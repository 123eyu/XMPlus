package teikengstudio.xmplus

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.util.Base64
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException
import java.security.MessageDigest

/** Shares only individual files explicitly opened by this app, never a storage root. */
class SharedAudioProvider : ContentProvider() {
    companion object {
        private const val FILES = "shared_audio_files"

        fun uriForFile(context: Context, file: File): Uri {
            require(file.isAbsolute && file.isFile && file.canRead()) { "Audio file is not readable" }
            val path = file.canonicalPath
            val id = Base64.encodeToString(
                MessageDigest.getInstance("SHA-256").digest(path.toByteArray(Charsets.UTF_8)),
                Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
            )
            val files = context.getSharedPreferences(FILES, Context.MODE_PRIVATE)
            if (files.getString(id, null) != path) {
                check(files.edit().putString(id, path).commit()) { "Cannot register audio file for sharing" }
            }
            return Uri.Builder().scheme("content").authority("${context.packageName}.audio")
                .appendPath(id).build()
        }
    }

    override fun onCreate(): Boolean = true

    private fun file(uri: Uri): File {
        val context = requireNotNull(context)
        if (uri.authority != "${context.packageName}.audio" || uri.pathSegments.size != 1) {
            throw FileNotFoundException("Invalid audio URI")
        }
        val path = context.getSharedPreferences(FILES, Context.MODE_PRIVATE)
            .getString(uri.lastPathSegment, null) ?: throw FileNotFoundException("Unknown audio URI")
        val file = File(path)
        if (file.canonicalPath != path || !file.isFile || !file.canRead()) {
            throw FileNotFoundException("Audio file is no longer available")
        }
        return file
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Audio sharing is read-only")
        return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String {
        file(uri)
        return "audio/*"
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
                       selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val file = file(uri)
        val columns = (projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE))
            .filter { it == OpenableColumns.DISPLAY_NAME || it == OpenableColumns.SIZE }.toTypedArray()
        return MatrixCursor(columns, 1).apply {
            addRow(columns.map { if (it == OpenableColumns.DISPLAY_NAME) file.name else file.length() })
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri = throw SecurityException("Read-only provider")
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
        throw SecurityException("Read-only provider")
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw SecurityException("Read-only provider")
}
