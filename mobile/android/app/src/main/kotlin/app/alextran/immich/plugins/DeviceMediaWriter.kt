package app.alextran.immich.plugins

import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.exifinterface.media.ExifInterface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class DeviceMediaWriter(private val activity: ComponentActivity, messenger: BinaryMessenger) :
  MethodChannel.MethodCallHandler {
  private val channel = MethodChannel(messenger, CHANNEL)
  private val mainHandler = Handler(Looper.getMainLooper())
  private val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "device-media-writer") }
  private var pendingGrant: ((Boolean) -> Unit)? = null
  private val privateFiles = PrivateFiles(activity)
  private val launcher = activity.registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) {
    val callback = pendingGrant
    pendingGrant = null
    callback?.invoke(it.resultCode == Activity.RESULT_OK)
  }

  init {
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "overwriteImage" -> {
        val id = call.argument<String>("id")!!
        val source = File(call.argument<String>("sourcePath")!!)
        val exifSource = call.argument<String>("exifSourcePath")?.let(::File)
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id.toLong())
        overwrite(uri, source, exifSource, width, height, result, allowPrompt = true)
      }

      "moveToFolder" -> {
        val items = call.argument<List<Map<String, Any>>>("items") ?: emptyList()
        val relativePath = call.argument<String>("relativePath")!!
        val uris = items.map { item ->
          val collection = if (item["video"] == true) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
          } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
          }
          ContentUris.withAppendedId(collection, (item["id"] as String).toLong())
        }
        move(uris, relativePath, result, allowPrompt = true)
      }

      "privateHasAccess" -> result.success(privateFiles.hasAccess())

      "privateRequestAccess" -> {
        privateFiles.requestAccess()
        result.success(null)
      }

      "privateHide" -> {
        val items = call.argument<List<Map<String, Any?>>>("items") ?: emptyList()
        background(result) { privateFiles.hide(items) }
      }

      "privateUnhide" -> {
        val file = call.argument<String>("file")!!
        val originalPath = call.argument<String>("originalPath")!!
        background(result) { privateFiles.unhide(file, originalPath) }
      }

      "privateDelete" -> {
        val file = call.argument<String>("file")!!
        background(result) { privateFiles.delete(file) }
      }

      "listTrashed" -> background(result) { listTrashed() }

      "trashThumbnail" -> {
        val id = call.argument<String>("id")!!
        val video = call.argument<Boolean>("video") ?: false
        background(result) { trashThumbnail(id, video) }
      }

      "restoreTrashed", "deleteTrashed" -> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
          result.success(false)
          return
        }
        val uris = (call.argument<List<Map<String, Any?>>>("items") ?: emptyList()).map { item ->
          ContentUris.withAppendedId(
            if (item["video"] == true) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            (item["id"] as String).toLong(),
          )
        }
        if (uris.isEmpty()) {
          result.success(true)
          return
        }
        val request = if (call.method == "restoreTrashed") {
          MediaStore.createTrashRequest(activity.contentResolver, uris, false)
        } else {
          MediaStore.createDeleteRequest(activity.contentResolver, uris)
        }
        pendingGrant = { granted -> result.success(granted) }
        launcher.launch(IntentSenderRequest.Builder(request.intentSender).build())
      }

      "exportToFiles" -> {
        val items = call.argument<List<Map<String, Any?>>>("items") ?: emptyList()
        exportToFiles(items, result)
      }

      else -> result.notImplemented()
    }
  }

  private fun listTrashed(): List<Map<String, Any?>> {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
      return emptyList()
    }
    val items = mutableListOf<Map<String, Any?>>()
    for ((collection, video) in listOf(
      MediaStore.Images.Media.EXTERNAL_CONTENT_URI to false,
      MediaStore.Video.Media.EXTERNAL_CONTENT_URI to true,
    )) {
      val args = android.os.Bundle().apply {
        putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_ONLY)
      }
      val columns = arrayOf(
        MediaStore.MediaColumns._ID,
        MediaStore.MediaColumns.DISPLAY_NAME,
        MediaStore.MediaColumns.DATE_EXPIRES,
        MediaStore.MediaColumns.DATE_TAKEN,
      )
      activity.contentResolver.query(collection, columns, args, null)?.use { cursor ->
        while (cursor.moveToNext()) {
          items.add(
            mapOf(
              "id" to cursor.getLong(0).toString(),
              "name" to cursor.getString(1),
              "expires" to if (cursor.isNull(2)) null else cursor.getLong(2) * 1000,
              "takenAt" to if (cursor.isNull(3)) null else cursor.getLong(3),
              "video" to video,
            ),
          )
        }
      }
    }
    return items.sortedByDescending { it["expires"] as Long? ?: 0L }
  }

  private fun trashThumbnail(id: String, video: Boolean): String? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
      return null
    }
    val target = File(File(activity.cacheDir, "trash_thumbs").apply { mkdirs() }, "$id.jpg")
    if (target.exists()) {
      return target.absolutePath
    }
    val uri = ContentUris.withAppendedId(
      if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
      id.toLong(),
    )
    return runCatching {
      val bitmap = activity.contentResolver.loadThumbnail(uri, android.util.Size(256, 256), null)
      target.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, it) }
      bitmap.recycle()
      target.absolutePath
    }.getOrNull()
  }

  private fun background(result: MethodChannel.Result, block: () -> Any?) {
    executor.execute {
      try {
        val value = block()
        mainHandler.post { result.success(if (value == Unit) null else value) }
      } catch (error: Throwable) {
        mainHandler.post { result.error("private_failed", error.message ?: error.toString(), null) }
      }
    }
  }

  private fun exportToFiles(items: List<Map<String, Any?>>, result: MethodChannel.Result) {
    val pool = Executors.newFixedThreadPool(4)
    executor.execute {
      val succeeded = java.util.Collections.synchronizedList(mutableListOf<Map<String, String?>>())
      val tasks = items.map { item ->
        pool.submit(Runnable {
          val id = item["id"] as String
          val collection = if (item["video"] == true) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
          } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
          }
          val uri = ContentUris.withAppendedId(collection, id.toLong())
          try {
            val target = File(item["dest"] as String)
            activity.contentResolver.openInputStream(uri)?.use { input ->
              target.outputStream().use { input.copyTo(it, 1 shl 16) }
            } ?: return@Runnable
            (item["thumb"] as String?)?.let { thumbPath ->
              if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                runCatching {
                  val bitmap = activity.contentResolver.loadThumbnail(uri, android.util.Size(320, 320), null)
                  File(thumbPath).outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, it) }
                  bitmap.recycle()
                }
              }
            }
            val relativePath = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
              activity.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.RELATIVE_PATH), null, null, null)
                ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
            } else {
              null
            }
            succeeded.add(mapOf("id" to id, "relativePath" to relativePath))
          } catch (_: Throwable) {
            File(item["dest"] as String).delete()
          }
        })
      }
      tasks.forEach { runCatching { it.get() } }
      pool.shutdown()
      val ids = succeeded.toList()
      mainHandler.post { result.success(ids) }
    }
  }

  private fun move(uris: List<Uri>, relativePath: String, result: MethodChannel.Result, allowPrompt: Boolean) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
      result.error("unsupported", "Moving between albums needs Android 10 or newer", null)
      return
    }
    executor.execute {
      try {
        val values = ContentValues().apply { put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath) }
        var moved = 0
        for (uri in uris) {
          moved += activity.contentResolver.update(uri, values, null, null)
        }
        mainHandler.post { result.success(moved) }
      } catch (error: SecurityException) {
        if (!allowPrompt) {
          mainHandler.post { result.error("write_denied", error.message, null) }
          return@execute
        }
        mainHandler.post {
          requestWriteAccess(uris, error) { granted ->
            if (granted) {
              move(uris, relativePath, result, allowPrompt = false)
            } else {
              result.error("write_denied", "Permission to move the photos was denied", null)
            }
          }
        }
      } catch (error: Throwable) {
        mainHandler.post { result.error("move_failed", error.message ?: error.toString(), null) }
      }
    }
  }

  private fun overwrite(
    uri: Uri,
    source: File,
    exifSource: File?,
    width: Int?,
    height: Int?,
    result: MethodChannel.Result,
    allowPrompt: Boolean,
  ) {
    executor.execute {
      try {
        write(uri, source, exifSource, width, height)
        mainHandler.post { result.success(true) }
      } catch (error: SecurityException) {
        if (!allowPrompt) {
          mainHandler.post { result.error("write_denied", error.message, null) }
          return@execute
        }
        mainHandler.post {
          requestWriteAccess(listOf(uri), error) { granted ->
            if (granted) {
              overwrite(uri, source, exifSource, width, height, result, allowPrompt = false)
            } else {
              result.error("write_denied", "Permission to modify the photo was denied", null)
            }
          }
        }
      } catch (error: Throwable) {
        mainHandler.post { result.error("write_failed", error.message ?: error.toString(), null) }
      }
    }
  }

  private fun requestWriteAccess(uris: List<Uri>, error: SecurityException, callback: (Boolean) -> Unit) {
    val sender = when {
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
        MediaStore.createWriteRequest(activity.contentResolver, uris).intentSender

      Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && error is RecoverableSecurityException ->
        error.userAction.actionIntent.intentSender

      else -> null
    }
    if (sender == null) {
      callback(false)
      return
    }
    pendingGrant = callback
    launcher.launch(IntentSenderRequest.Builder(sender).build())
  }

  private fun write(uri: Uri, source: File, exifSource: File?, width: Int?, height: Int?) {
    val resolver = activity.contentResolver
    resolver.openOutputStream(uri, "wt")?.use { output ->
      source.inputStream().use { it.copyTo(output) }
    } ?: throw IllegalStateException("Unable to open the photo for writing")

    if (exifSource == null || !exifSource.exists()) {
      return
    }
    val original = ExifInterface(exifSource)
    resolver.openFileDescriptor(uri, "rw")?.use { descriptor ->
      val target = ExifInterface(descriptor.fileDescriptor)
      for (tag in COPIED_TAGS) {
        original.getAttribute(tag)?.let { target.setAttribute(tag, it) }
      }
      target.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
      if (width != null && height != null) {
        target.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, width.toString())
        target.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, height.toString())
      }
      target.saveAttributes()
    }
  }

  companion object {
    const val CHANNEL = "immich/device_media"

    private val COPIED_TAGS = listOf(
      ExifInterface.TAG_DATETIME,
      ExifInterface.TAG_DATETIME_ORIGINAL,
      ExifInterface.TAG_DATETIME_DIGITIZED,
      ExifInterface.TAG_OFFSET_TIME,
      ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
      ExifInterface.TAG_OFFSET_TIME_DIGITIZED,
      ExifInterface.TAG_SUBSEC_TIME,
      ExifInterface.TAG_SUBSEC_TIME_ORIGINAL,
      ExifInterface.TAG_SUBSEC_TIME_DIGITIZED,
      ExifInterface.TAG_GPS_LATITUDE,
      ExifInterface.TAG_GPS_LATITUDE_REF,
      ExifInterface.TAG_GPS_LONGITUDE,
      ExifInterface.TAG_GPS_LONGITUDE_REF,
      ExifInterface.TAG_GPS_ALTITUDE,
      ExifInterface.TAG_GPS_ALTITUDE_REF,
      ExifInterface.TAG_GPS_TIMESTAMP,
      ExifInterface.TAG_GPS_DATESTAMP,
      ExifInterface.TAG_MAKE,
      ExifInterface.TAG_MODEL,
      ExifInterface.TAG_LENS_MAKE,
      ExifInterface.TAG_LENS_MODEL,
      ExifInterface.TAG_F_NUMBER,
      ExifInterface.TAG_EXPOSURE_TIME,
      ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
      ExifInterface.TAG_FOCAL_LENGTH,
      ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
      ExifInterface.TAG_FLASH,
      ExifInterface.TAG_WHITE_BALANCE,
      ExifInterface.TAG_IMAGE_DESCRIPTION,
      ExifInterface.TAG_ARTIST,
      ExifInterface.TAG_COPYRIGHT,
      ExifInterface.TAG_SOFTWARE,
    )
  }
}
