package app.alextran.immich.plugins.api

import android.content.Context
import java.io.File

interface ImmichPlugin {
  fun call(method: String, input: String, host: PluginHost): String?
}

interface PluginHost {
  val context: Context
  val dataDir: File
  val pluginName: String

  fun callHost(name: String, argsJson: String): String
}
