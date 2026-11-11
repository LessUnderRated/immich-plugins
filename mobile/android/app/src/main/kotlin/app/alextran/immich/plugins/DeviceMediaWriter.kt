package app.alextran.immich.plugins

import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.ContentUris
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

      else -> result.notImplemented()
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
          requestWriteAccess(uri, error) { granted ->
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

  private fun requestWriteAccess(uri: Uri, error: SecurityException, callback: (Boolean) -> Unit) {
    val sender = when {
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
        MediaStore.createWriteRequest(activity.contentResolver, listOf(uri)).intentSender

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
