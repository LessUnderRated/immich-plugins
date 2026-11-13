package app.alextran.immich.plugins

import android.app.Activity
import android.content.Context
import app.alextran.immich.plugins.api.PluginHost
import java.io.File

/**
 * The host given to plugins called while the app's plugin host is not running (background work, notification actions
 * in a cold process, startup loads before Flutter starts). Natively implemented host functions work; the others
 * answer 503. Directories match DexPluginHost's.
 */
internal class HeadlessPluginHost(
  override val context: Context,
  override val pluginName: String,
  dexPath: String?,
) : PluginHost {
  override val dataDir: File = File(context.filesDir, "dex-plugin-data/$pluginName").apply { mkdirs() }

  override val pluginDir: File = dexPath?.let { File(File(it).parentFile, "files") } ?: dataDir

  override val activity: Activity?
    get() = PluginLifecycle.currentActivity

  override fun callHost(name: String, argsJson: String): String =
    PluginHostFunctions.tryCall(pluginName, name, argsJson)
      ?: PluginJson.error(503, "Host function $name needs the app's plugin host, which is not running")

  override fun runOnUi(block: Runnable) {
    PluginRuntime.mainHandler.post(PluginCrashGuard.wrap(pluginName, "runOnUi", block))
  }

  override fun sendEvent(name: String, payloadJson: String) {
    PluginNativeBridge.command(pluginName, name, payloadJson)
  }
}
