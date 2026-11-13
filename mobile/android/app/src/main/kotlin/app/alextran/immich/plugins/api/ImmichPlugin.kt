package app.alextran.immich.plugins.api

import android.app.Activity
import android.content.Context
import android.view.View
import org.json.JSONObject
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

/**
 * Receives the JSON envelope of an asynchronous host call (`{"success": true, "response": ...}` or
 * `{"success": false, "status", "message"}`). Called on a background thread, never on the UI thread.
 */
fun interface HostCallback {
  fun onResult(resultJson: String)
}

/**
 * What the app gives a plugin. Methods added after v1 have default implementations, so plugins compiled against the
 * v1 interface keep loading and running; the app's own implementation overrides all of them.
 */
interface PluginHost {
  val context: Context
  val dataDir: File
  val pluginDir: File
  val pluginName: String
  val activity: Activity?

  /** Calls a host function and blocks until it answers (up to 5 minutes). Never call it on the UI thread. */
  fun callHost(name: String, argsJson: String): String

  fun runOnUi(block: Runnable)

  /** Runs an app command (`toast`, `openUiPage`, `dialog`, ...); see PLUGINS.md "Commands". */
  fun sendEvent(name: String, payloadJson: String)

  /** Host API version: 1 for the original API, 2 once [callHostAsync] and [emit] exist. */
  val hostApiVersion: Int
    get() = 1

  /**
   * Calls a host function without blocking; [callback] receives the result envelope on a background thread. Safe to
   * call from any thread, including the UI thread.
   */
  fun callHostAsync(name: String, argsJson: String, callback: HostCallback) {
    Thread { callback.onResult(callHost(name, argsJson)) }.start()
  }

  /**
   * Emits a plugin event (`event` name, JSON object payload) on the app's event bus. Other plugins subscribed to it
   * in their manifest `events` receive it as `EventV1` with `"source": <this plugin>`; the emitting plugin does not.
   */
  fun emit(event: String, payloadJson: String) {
    callHostAsync("events.emit", "[${JSONObject.quote(event)},${payloadJson.ifBlank { "null" }}]") { }
  }

  /**
   * Native capabilities of this plugin (lifecycle, intents, permissions, notifications, background work, media,
   * video sessions, views, other plugins, native host functions); see docs/plugins/native.md. Same as
   * `ImmichNative.of(host)`.
   */
  val native: NativeHost
    get() = ImmichNative.of(this)
}
