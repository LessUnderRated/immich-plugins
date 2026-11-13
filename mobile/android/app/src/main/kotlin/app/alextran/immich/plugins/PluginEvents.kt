package app.alextran.immich.plugins

import app.alextran.immich.plugins.api.NativeEventListener
import app.alextran.immich.plugins.api.Registration
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Native side of the plugin event bus. Native events are delivered to native listeners directly and sent to Dart
 * (the kernel delivers them to manifest subscribers). Their payload carries `"origin": "native"` so the Dart side does
 * not forward them back. App events from Dart arrive through [dispatchFromDart] for the patterns native listeners
 * subscribed to (reported to Dart with `subscriptions`).
 */
internal object PluginEvents {
  private class Subscription(val plugin: String, val pattern: String, val listener: NativeEventListener)

  private val subscriptions = CopyOnWriteArrayList<Subscription>()

  /** Emits a native event. [data] is modified (adds `origin`). */
  fun emit(event: String, data: JSONObject, source: String? = null) {
    data.put("origin", "native")
    if (source != null && !data.has("source")) {
      data.put("source", source)
    }
    val json = data.toString()
    dispatchLocal(event, json)
    PluginNativeBridge.emit(event, json, source)
  }

  /** An event a plugin emitted through `NativeEvents.emit`. */
  fun emitFromPlugin(plugin: String, event: String, payloadJson: String) {
    require(event.isNotBlank()) { "event name is required" }
    emit(event, PluginJson.obj(payloadJson), plugin)
  }

  fun dispatchFromDart(event: String, dataJson: String) = dispatchLocal(event, dataJson)

  private fun dispatchLocal(event: String, json: String) {
    if (subscriptions.isEmpty()) {
      return
    }
    val matching = subscriptions.filter { matches(it.pattern, event) }
    if (matching.isEmpty()) {
      return
    }
    PluginRuntime.runOnMain {
      for (subscription in matching) {
        PluginCrashGuard.run(subscription.plugin, "event $event") { subscription.listener.onEvent(event, json) }
      }
    }
  }

  fun addListener(plugin: String, pattern: String, listener: NativeEventListener): Registration {
    require(pattern.isNotBlank()) { "pattern is required" }
    val subscription = Subscription(plugin, pattern, listener)
    subscriptions.add(subscription)
    PluginNativeBridge.subscriptions(patterns())
    return PluginRuntime.scope(plugin).track {
      subscriptions.remove(subscription)
      PluginNativeBridge.subscriptions(patterns())
    }
  }

  fun patterns(): List<String> = subscriptions.map { it.pattern }.distinct()

  fun matches(pattern: String, event: String): Boolean = when {
    pattern == "*" || pattern == event -> true
    pattern.endsWith(".*") -> event.startsWith(pattern.dropLast(1))
    else -> false
  }
}
