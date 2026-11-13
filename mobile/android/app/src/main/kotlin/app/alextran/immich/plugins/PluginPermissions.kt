package app.alextran.immich.plugins

import android.app.Activity
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Runtime permissions and activity results for plugins, launched from the activity in front through its
 * ActivityResultRegistry (no activity changes needed; results arrive through the activity's normal forwarding).
 * Pending requests whose activity is destroyed complete with no result.
 */
internal object PluginActivityResults {
  private class Pending(val activity: WeakReference<Activity>, val fail: () -> Unit)

  private val counter = AtomicInteger()
  private val pending = ConcurrentHashMap<String, Pending>()

  /** Launches [contract] with [input]; [callback] runs once on the main thread with the output, or null on failure. */
  fun <I, O> launch(contract: ActivityResultContract<I, O>, input: I, callback: (O?) -> Unit) {
    PluginRuntime.runOnMain {
      val activity = PluginLifecycle.resultActivity()
      if (activity == null) {
        Log.w(PluginRuntime.TAG, "No activity to launch a plugin request from")
        callback(null)
        return@runOnMain
      }
      val key = "immich.plugins.result.${counter.incrementAndGet()}"
      val done = AtomicBoolean(false)
      var launcher: ActivityResultLauncher<I>? = null
      val finish: (O?) -> Unit = { output ->
        if (done.compareAndSet(false, true)) {
          pending.remove(key)
          val registered = launcher
          PluginRuntime.mainHandler.post { registered?.unregister() }
          callback(output)
        }
      }
      try {
        val registered = activity.activityResultRegistry.register(key, contract) { output -> finish(output) }
        launcher = registered
        pending[key] = Pending(WeakReference(activity)) { finish(null) }
        registered.launch(input)
      } catch (error: Throwable) {
        Log.w(PluginRuntime.TAG, "Unable to launch a plugin request", error)
        finish(null)
      }
    }
  }

  fun onActivityDestroyed(activity: Activity) {
    for ((_, request) in pending) {
      if (request.activity.get() === activity || request.activity.get() == null) {
        request.fail()
      }
    }
  }

  // ---- permissions ----------------------------------------------------------------------------------------------

  fun isGranted(permission: String): Boolean =
    PluginRuntime.context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

  fun shouldShowRationale(permission: String): Boolean =
    PluginLifecycle.currentActivity?.shouldShowRequestPermissionRationale(permission) ?: false

  /** Requests the missing [permissions]; [callback] gets all of them with their state (main thread). */
  fun requestPermissions(plugin: String?, permissions: List<String>, callback: (Map<String, Boolean>) -> Unit) {
    val missing = permissions.distinct().filterNot(::isGranted)
    if (missing.isEmpty()) {
      PluginRuntime.runOnMain { callback(permissions.associateWith { true }) }
      return
    }
    launch(ActivityResultContracts.RequestMultiplePermissions(), missing.toTypedArray()) { output ->
      val results = permissions.associateWith { permission -> output?.get(permission) ?: isGranted(permission) }
      PluginEvents.emit(
        "permissions.result",
        JSONObject().put("plugin", plugin).put("results", PluginJson.toJson(results)),
      )
      callback(results)
    }
  }

  fun openAppSettings() {
    val context = PluginRuntime.context
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
    val activity = PluginLifecycle.currentActivity
    if (activity != null) {
      activity.startActivity(intent)
    } else {
      context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
  }

  // ---- activity results -----------------------------------------------------------------------------------------

  fun startActivityForResult(intent: Intent, callback: (Int, Intent?) -> Unit) {
    launch(ActivityResultContracts.StartActivityForResult(), intent) { result ->
      callback(result?.resultCode ?: Activity.RESULT_CANCELED, result?.data)
    }
  }

  fun startIntentSenderForResult(sender: IntentSender, callback: (Int, Intent?) -> Unit) {
    launch(ActivityResultContracts.StartIntentSenderForResult(), IntentSenderRequest.Builder(sender).build()) { result ->
      callback(result?.resultCode ?: Activity.RESULT_CANCELED, result?.data)
    }
  }
}
