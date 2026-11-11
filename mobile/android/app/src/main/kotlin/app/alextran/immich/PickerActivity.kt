package app.alextran.immich

import android.app.Activity
import android.content.ClipData
import android.content.ContentUris
import android.content.Intent
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bottom-sheet picker other apps open with ACTION_GET_CONTENT or ACTION_PICK.
 * Runs the `pickerMain` Dart entrypoint on its own engine and returns MediaStore URIs.
 */
class PickerActivity : FlutterFragmentActivity() {
  override fun getDartEntrypointFunctionName(): String = "pickerMain"

  override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
    FlutterActivityLaunchConfigs.BackgroundMode.transparent

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
      when (call.method) {
        "getRequest" -> result.success(
          mapOf(
            "mimeType" to requestedMimeType(),
            "multiple" to intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false),
          ),
        )

        "finish" -> {
          val items = call.argument<List<Map<String, Any?>>>("items") ?: emptyList()
          deliver(items)
          result.success(null)
        }

        "cancel" -> {
          setResult(Activity.RESULT_CANCELED)
          finish()
          result.success(null)
        }

        else -> result.notImplemented()
      }
    }
  }

  private fun requestedMimeType(): String {
    val types = listOfNotNull(intent.type) + (intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES)?.toList() ?: emptyList())
    if (types.isEmpty() || types.any { it.startsWith("*") || it.contains("cursor.dir/*") }) {
      return "*/*"
    }
    val wantsImages = types.any { it.contains("image") }
    val wantsVideos = types.any { it.contains("video") }
    return when {
      wantsVideos && !wantsImages -> "video/*"
      wantsImages && !wantsVideos -> "image/*"
      else -> "*/*"
    }
  }

  private fun deliver(items: List<Map<String, Any?>>) {
    val uris = items.map { item ->
      val privateFile = item["file"] as String?
      if (privateFile != null) {
        return@map FileProvider.getUriForFile(this, "${packageName}.privatefiles", java.io.File(privateFile))
      }
      val collection = if (item["video"] == true) {
        MediaStore.Video.Media.EXTERNAL_CONTENT_URI
      } else {
        MediaStore.Images.Media.EXTERNAL_CONTENT_URI
      }
      ContentUris.withAppendedId(collection, (item["id"] as String).toLong())
    }
    if (uris.isEmpty()) {
      setResult(Activity.RESULT_CANCELED)
      finish()
      return
    }

    val data = Intent().apply {
      setDataAndType(uris.first(), (items.first()["mime"] as String?) ?: contentResolver.getType(uris.first()))
      clipData = ClipData.newUri(contentResolver, "media", uris.first()).also { clip ->
        uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
      }
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    setResult(Activity.RESULT_OK, data)
    finish()
  }

  private companion object {
    const val CHANNEL = "immich/picker"
  }
}
