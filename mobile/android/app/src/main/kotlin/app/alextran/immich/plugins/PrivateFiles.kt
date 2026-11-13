package app.alextran.immich.plugins

import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import java.io.File

/**
 * Hides photos from every other app by renaming them to `<name>.private` inside
 * Pictures/.immich_private (which also holds a .nomedia marker) and dropping them from
 * MediaStore. Needs all-files access on Android 11+.
 */
class PrivateFiles(private val context: Context) {
  private val privateDir: File
    get() = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), ".immich_private").apply {
      mkdirs()
      File(this, ".nomedia").takeIf { !it.exists() }?.createNewFile()
    }

  private val thumbDir: File
    get() = File(context.filesDir, "private_thumbs").apply { mkdirs() }

  fun hasAccess(): Boolean =
    Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()

  fun requestAccess() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
      return
    }
    val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
      .setData(Uri.parse("package:${context.packageName}"))
      .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(intent)
  }

  fun hide(items: List<Map<String, Any?>>): List<Map<String, Any?>> {
    val hidden = mutableListOf<Map<String, Any?>>()
    val removedPaths = mutableListOf<String>()
    for (item in items) {
      val id = item["id"] as String
      val video = item["video"] == true
      val collection = if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
      val uri = ContentUris.withAppendedId(collection, id.toLong())
      val info = query(uri, video) ?: continue
      val source = File(info.path)
      if (!source.exists()) {
        continue
      }

      val target = unique(File(privateDir, "${source.name}.private"))
      val thumb = File(thumbDir, "${target.name}.jpg")
      saveThumbnail(uri, thumb)

      if (!source.renameTo(target)) {
        source.copyTo(target, overwrite = false)
        if (!source.delete()) {
          target.delete()
          thumb.delete()
          continue
        }
      }
      if (info.modified > 0) target.setLastModified(info.modified)
      removedPaths.add(source.absolutePath)
      hidden.add(
        mapOf(
          "id" to id,
          "file" to target.absolutePath,
          "thumb" to thumb.takeIf { it.exists() }?.absolutePath,
          "originalPath" to source.absolutePath,
          "name" to source.name,
          "mime" to info.mime,
          "takenAt" to info.takenAt,
          "width" to info.width,
          "height" to info.height,
          "durationMs" to info.durationMs,
          "video" to video,
        ),
      )
    }
    if (removedPaths.isNotEmpty()) {
      MediaScannerConnection.scanFile(context, removedPaths.toTypedArray(), null, null)
    }
    return hidden
  }

  fun unhide(file: String, originalPath: String): String? {
    val source = File(file)
    if (!source.exists()) {
      return null
    }
    val target = unique(File(originalPath))
    target.parentFile?.mkdirs()
    if (!source.renameTo(target)) {
      source.copyTo(target, overwrite = false)
      source.delete()
    }
    File(thumbDir, "${source.name}.jpg").delete()
    MediaScannerConnection.scanFile(context, arrayOf(target.absolutePath), null, null)
    return target.absolutePath
  }

  fun delete(file: String) {
    val source = File(file)
    File(thumbDir, "${source.name}.jpg").delete()
    source.delete()
  }

  private data class Info(
    val path: String,
    val mime: String?,
    val takenAt: Long?,
    val modified: Long,
    val width: Int?,
    val height: Int?,
    val durationMs: Long?,
  )

  private fun query(uri: Uri, video: Boolean): Info? {
    val columns = mutableListOf(
      MediaStore.MediaColumns.DATA,
      MediaStore.MediaColumns.MIME_TYPE,
      MediaStore.MediaColumns.DATE_TAKEN,
      MediaStore.MediaColumns.DATE_MODIFIED,
      MediaStore.MediaColumns.WIDTH,
      MediaStore.MediaColumns.HEIGHT,
      MediaStore.MediaColumns.DATE_ADDED,
    )
    if (video) {
      columns.add(MediaStore.Video.VideoColumns.DURATION)
    }
    return context.contentResolver.query(uri, columns.toTypedArray(), null, null, null)?.use { cursor ->
      if (!cursor.moveToFirst()) {
        return@use null
      }
      fun long(index: Int) = if (cursor.isNull(index)) null else cursor.getLong(index)
      fun int(index: Int) = if (cursor.isNull(index)) null else cursor.getInt(index)
      val modified = (long(3) ?: 0L) * 1000
      val added = (long(6) ?: 0L) * 1000
      val fallback = if (modified <= 0) added else if (added <= 0) modified else minOf(modified, added)
      Info(
        path = cursor.getString(0) ?: return@use null,
        mime = cursor.getString(1),
        takenAt = long(2)?.takeIf { it > 0 } ?: fallback.takeIf { it > 0 },
        modified = modified,
        width = int(4),
        height = int(5),
        durationMs = if (video) long(7) else null,
      )
    }
  }

  private fun saveThumbnail(uri: Uri, target: File) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
      return
    }
    runCatching {
      val bitmap = context.contentResolver.loadThumbnail(uri, Size(320, 320), null)
      target.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }
      bitmap.recycle()
    }
  }

  private fun unique(file: File): File {
    if (!file.exists()) {
      return file
    }
    val parent = file.parentFile
    val name = file.name
    val dot = name.indexOf('.')
    val base = if (dot > 0) name.substring(0, dot) else name
    val extension = if (dot > 0) name.substring(dot) else ""
    var index = 1
    while (true) {
      val candidate = File(parent, "$base ($index)$extension")
      if (!candidate.exists()) {
        return candidate
      }
      index++
    }
  }
}
