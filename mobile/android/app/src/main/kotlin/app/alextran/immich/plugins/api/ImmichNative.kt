package app.alextran.immich.plugins.api

import app.alextran.immich.plugins.PluginRuntime

/**
 * Entry point of the native plugin API (see docs/plugins/native.md).
 *
 * `ImmichNative.of(host)` returns the [NativeHost] of the calling plugin. Apps older than this API do not have this
 * class: catch [NoClassDefFoundError] around the first call, or call the host function `native.info`, which answers
 * `{ "success": false, "status": 501 }` there.
 */
object ImmichNative {
  /** Version of the native API in the app the plugin was compiled against. Compare with [apiVersion] at runtime. */
  const val API_VERSION: Int = 1

  @JvmStatic
  fun of(host: PluginHost): NativeHost = PluginRuntime.nativeHost(host.pluginName)

  /** Version of the native API the running app implements. */
  @JvmStatic
  fun apiVersion(): Int = PluginRuntime.API_VERSION

  /** Feature flags of the running app, e.g. `video.capture`, `notifications`, `work`. */
  @JvmStatic
  fun features(): Set<String> = PluginRuntime.FEATURES
}

/**
 * Optional interface for the plugin entry class: called after the plugin is loaded (by the app, by background work,
 * a notification action or a startup load) and before it is unloaded. Register native listeners in [onLoad]; every
 * registration made through [NativeHost] is removed automatically after [onUnload].
 */
interface ImmichPluginLifecycle {
  fun onLoad(host: PluginHost) {}

  fun onUnload(host: PluginHost) {}
}

/** A listener, interceptor, service or function registration. [remove] is idempotent. */
fun interface Registration {
  fun remove()
}

/** Receives a JSON result envelope: `{ "success": true, "response": ... }` or `{ "success": false, "status", "message" }`. */
fun interface ResultCallback {
  fun onResult(resultJson: String)
}
