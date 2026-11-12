package app.alextran.immich.plugins.api

import android.app.Activity
import android.content.Context
import android.view.View
import java.io.File

interface ImmichPlugin {
  fun call(method: String, input: String, host: PluginHost): String?
}

interface ImmichViewPlugin {
  fun createView(context: Context, viewType: String, params: String, host: PluginHost): View
}

interface ImmichViewLifecycle {
  fun onViewDisposed(viewType: String, view: View)
}

interface PluginHost {
  val context: Context
  val dataDir: File
  val pluginDir: File
  val pluginName: String
  val activity: Activity?

  fun callHost(name: String, argsJson: String): String

  fun runOnUi(block: Runnable)

  fun sendEvent(name: String, payloadJson: String)
}
