package app.alextran.immich.plugins

import android.Manifest
import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.IntentSender
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.exifinterface.media.ExifInterface
import app.alextran.immich.plugins.PluginJson.intOrNull
import app.alextran.immich.plugins.PluginJson.longOrNull
import app.alextran.immich.plugins.PluginJson.str
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * MediaStore writes for plugins and the app's generic `media.*` host functions: new photos and videos in the device
 * gallery, and in-place replacement with an optional backup of the original. Used by the `immich/device_media`
 * channel (`saveMedia`, `replaceMedia`) and by [app.alextran.immich.plugins.api.NativeMedia].
 */
internal object PluginMedia {
  private val imageDirectories = listOf(Environment.DIRECTORY_DCIM, Environment.DIRECTORY_PICTURES)
  private val videoDirectories = listOf(Environment.DIRECTORY_DCIM, Environment.DIRECTORY_MOVIES)

  private fun collection(video: Boolean): Uri =
    if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI

  fun uri(id: String, video: Boolean): Uri = ContentUris.withAppendedId(collection(video), id.toLong())

  /**
   * Adds [source] to the gallery. [options]: `displayName`, `mimeType`, `relativePath` (e.g. `Pictures/Immich`; must
   * start with DCIM or Pictures for photos, DCIM or Movies for videos, otherwise it is placed under the default),
   * `dateTakenMs`, `exifSourcePath` (copy EXIF from this file, photos), `deleteSource`.
   * Returns `{ id, uri, displayName, relativePath, mimeType, video, path? }`. Blocking; may throw.
   */
  fun save(context: Context, source: File, options: JSONObject, video: Boolean): JSONObject {
    require(source.isFile) { "${source.path} does not exist" }
    val displayName = options.str("displayName") ?: source.name
    val mimeType = options.str("mimeType") ?: guessMime(displayName, video)
    val relativePath = relativePath(options.str("relativePath"), video)
    val dateTaken = options.longOrNull("dateTakenMs")
    val exifSource = options.str("exifSourcePath")?.let(::File)

    val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      saveScoped(context, source, displayName, mimeType, relativePath, dateTaken, exifSource, video)
    } else {
      saveLegacy(context, source, displayName, mimeType, relativePath, exifSource, video)
    }
    if (options.optBoolean("deleteSource", false)) {
      source.delete()
    }
    return result
  }

  private fun saveScoped(
    context: Context,
    source: File,
    displayName: String,
    mimeType: String,
    relativePath: String,
    dateTaken: Long?,
    exifSource: File?,
    video: Boolean,
  ): JSONObject {
    val resolver = context.contentResolver
    val values = ContentValues().apply {
      put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
      put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
      put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
      put(MediaStore.MediaColumns.IS_PENDING, 1)
      if (dateTaken != null) {
        put(MediaStore.MediaColumns.DATE_TAKEN, dateTaken)
      }
    }
    val uri = resolver.insert(collection(video), values) ?: throw IOException("The gallery refused the new item")
    try {
      resolver.openOutputStream(uri, "w")?.use { output -> source.inputStream().use { it.copyTo(output, 1 shl 16) } }
        ?: throw IOException("Unable to open the new item for writing")
      if (!video && exifSource != null) {
        copyExif(context, uri, exifSource, null, null)
      }
      resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
    } catch (error: Throwable) {
      resolver.delete(uri, null, null)
      throw error
    }
    val finalName = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)
      ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null } ?: displayName
    return JSONObject()
      .put("id", ContentUris.parseId(uri).toString())
      .put("uri", uri.toString())
      .put("displayName", finalName)
      .put("relativePath", relativePath)
      .put("mimeType", mimeType)
      .put("video", video)
  }

  @Suppress("DEPRECATION")
  private fun saveLegacy(
    context: Context,
    source: File,
    displayName: String,
    mimeType: String,
    relativePath: String,
    exifSource: File?,
    video: Boolean,
  ): JSONObject {
    if (context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
      throw SecurityException("Saving to the gallery needs the storage permission on this Android version")
    }
    val directory = File(Environment.getExternalStorageDirectory(), relativePath).apply { mkdirs() }
    val target = unique(File(directory, displayName))
    source.copyTo(target)
    if (!video && exifSource != null && exifSource.exists()) {
      try {
        copyTags(ExifInterface(exifSource), ExifInterface(target.absolutePath), null, null)
      } catch (_: Throwable) {
        // EXIF is best effort; unsupported formats keep their own metadata.
      }
    }
    val latch = CountDownLatch(1)
    var scanned: Uri? = null
    MediaScannerConnection.scanFile(context, arrayOf(target.absolutePath), arrayOf(mimeType)) { _, uri ->
      scanned = uri
      latch.countDown()
    }
    latch.await(15, TimeUnit.SECONDS)
    val uri = scanned ?: throw IOException("The gallery did not index ${target.name}")
    return JSONObject()
      .put("id", ContentUris.parseId(uri).toString())
      .put("uri", uri.toString())
      .put("displayName", target.name)
      .put("relativePath", relativePath)
      .put("mimeType", mimeType)
      .put("video", video)
      .put("path", target.absolutePath)
  }

  /**
   * Replaces device asset [id] with [source]. [options]: `backupPath` (copy the current file there first, unless it
   * already exists or `overwriteBackup`), `exifSourcePath` (photos: copy EXIF and reset orientation), `width`,
   * `height`. Asks the user for write access when needed. [callback] gets the result or the error.
   */
  fun replace(context: Context, id: String, video: Boolean, source: File, options: JSONObject, callback: (JSONObject?, Throwable?) -> Unit) {
    replace(context, id, video, source, options, allowPrompt = true, callback)
  }

  private fun replace(
    context: Context,
    id: String,
    video: Boolean,
    source: File,
    options: JSONObject,
    allowPrompt: Boolean,
    callback: (JSONObject?, Throwable?) -> Unit,
  ) {
    PluginRuntime.executor.execute {
      val uri = try {
        uri(id, video)
      } catch (error: Throwable) {
        callback(null, error)
        return@execute
      }
      try {
        callback(replaceNow(context, uri, id, video, source, options), null)
      } catch (error: SecurityException) {
        if (!allowPrompt) {
          callback(null, error)
          return@execute
        }
        requestWriteAccess(context, listOf(uri), error) { granted ->
          if (granted) {
            replace(context, id, video, source, options, allowPrompt = false, callback)
          } else {
            callback(null, SecurityException("Permission to modify the item was denied"))
          }
        }
      } catch (error: Throwable) {
        callback(null, error)
      }
    }
  }

  private fun replaceNow(context: Context, uri: Uri, id: String, video: Boolean, source: File, options: JSONObject): JSONObject {
    require(source.isFile) { "${source.path} does not exist" }
    val resolver = context.contentResolver
    val backup = options.str("backupPath")?.let(::File)
    if (backup != null && (!backup.exists() || options.optBoolean("overwriteBackup", false))) {
      backup.parentFile?.mkdirs()
      resolver.openInputStream(uri)?.use { input -> backup.outputStream().use { input.copyTo(it, 1 shl 16) } }
        ?: throw IOException("Unable to read the original")
    }
    resolver.openOutputStream(uri, "wt")?.use { output -> source.inputStream().use { it.copyTo(output, 1 shl 16) } }
      ?: throw IOException("Unable to open the item for writing")
    val exifSource = options.str("exifSourcePath")?.let(::File)
    if (!video && exifSource != null) {
      copyExif(context, uri, exifSource, options.intOrNull("width"), options.intOrNull("height"))
    }
    return JSONObject().put("id", id).put("uri", uri.toString()).put("replaced", true).put("backupPath", backup?.absolutePath)
  }

  /** Asks the user to allow writing [uris] (Android 10+); [callback] on the main thread. */
  fun requestWriteAccess(context: Context, uris: List<Uri>, error: SecurityException, callback: (Boolean) -> Unit) {
    val sender: IntentSender? = when {
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
        MediaStore.createWriteRequest(context.contentResolver, uris).intentSender

      Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && error is RecoverableSecurityException ->
        error.userAction.actionIntent.intentSender

      else -> null
    }
    if (sender == null) {
      PluginRuntime.runOnMain { callback(false) }
      return
    }
    PluginActivityResults.startIntentSenderForResult(sender) { resultCode, _ -> callback(resultCode == Activity.RESULT_OK) }
  }

  private fun copyExif(context: Context, uri: Uri, exifSource: File, width: Int?, height: Int?) {
    if (!exifSource.exists()) {
      return
    }
    try {
      val original = ExifInterface(exifSource)
      context.contentResolver.openFileDescriptor(uri, "rw")?.use { descriptor ->
        copyTags(original, ExifInterface(descriptor.fileDescriptor), width, height)
      }
    } catch (_: Throwable) {
      // EXIF is best effort; unsupported formats keep their own metadata.
    }
  }

  private fun copyTags(original: ExifInterface, target: ExifInterface, width: Int?, height: Int?) {
    for (tag in DeviceMediaWriter.COPIED_TAGS) {
      original.getAttribute(tag)?.let { target.setAttribute(tag, it) }
    }
    target.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
    if (width != null && height != null) {
      target.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, width.toString())
      target.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, height.toString())
    }
    target.saveAttributes()
  }

  private fun relativePath(requested: String?, video: Boolean): String {
    val allowed = if (video) videoDirectories else imageDirectories
    val fallbackRoot = if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
    val cleaned = requested?.trim()?.trim('/')?.takeIf { it.isNotEmpty() && !it.contains("..") } ?: "$fallbackRoot/Immich"
    val root = cleaned.substringBefore('/')
    val path = if (allowed.any { it.equals(root, ignoreCase = true) }) cleaned else "$fallbackRoot/$cleaned"
    return "$path/"
  }

  private fun guessMime(name: String, video: Boolean): String {
    val extension = name.substringAfterLast('.', "").lowercase()
    return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: if (video) "video/mp4" else "image/jpeg"
  }

  private fun unique(file: File): File {
    if (!file.exists()) {
      return file
    }
    val base = file.nameWithoutExtension
    val extension = file.extension.let { if (it.isEmpty()) "" else ".$it" }
    var index = 1
    while (true) {
      val candidate = File(file.parentFile, "$base ($index)$extension")
      if (!candidate.exists()) {
        return candidate
      }
      index++
    }
  }
}
