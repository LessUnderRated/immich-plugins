package app.alextran.immich.plugins

import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Method channel `immich/plugin_native` between the native runtime and the Dart plugin kernel.
 *
 * Dart to native: `attach`, `detach`, `info`, `call {plugin, name, args}`, `functions`, `dispatchEvent {event, data}`,
 * `setTheme {theme}`, `taskShow {...}`, `taskFinish {...}`, `taskCancel {id}`.
 * Native to Dart: `emit {event, data, plugin}`, `log {plugin, level, message, error, stack}`,
 * `command {plugin, name, payload}`, `perform {plugin, response}`, `subscriptions {patterns}`,
 * `contentHeight {viewId, height}`, `videoSessions {wanted}`.
 * Native-to-Dart messages sent before Dart called `attach` are queued (up to [MAX_QUEUE]) and delivered after it.
 */
internal object PluginNativeBridge : MethodChannel.MethodCallHandler {
  const val CHANNEL = "immich/plugin_native"
  private const val MAX_QUEUE = 256

  @Volatile
  private var channel: MethodChannel? = null

  @Volatile
  private var dartReady = false

  private val queue = ArrayDeque<Pair<String, Map<String, Any?>>>()

  val isDartAttached: Boolean get() = channel != null && dartReady

  fun attach(messenger: BinaryMessenger) {
    channel?.setMethodCallHandler(null)
    dartReady = false
    channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
  }

  fun detach() {
    channel?.setMethodCallHandler(null)
    channel = null
    dartReady = false
  }

  // ---- native to Dart -------------------------------------------------------------------------------------------

  fun emit(event: String, dataJson: String, plugin: String?) =
    send("emit", mapOf("event" to event, "data" to dataJson, "plugin" to plugin))

  fun log(plugin: String?, level: String, message: String, error: Throwable?) = send(
    "log",
    mapOf(
      "plugin" to plugin,
      "level" to level,
      "message" to message,
      "error" to error?.toString(),
      "stack" to error?.let { Log.getStackTraceString(it).take(8000) },
    ),
  )

  /** A command a plugin sent with `sendEvent` while the app's plugin host was not running. */
  fun command(plugin: String, name: String, payloadJson: String) =
    send("command", mapOf("plugin" to plugin, "name" to name, "payload" to payloadJson))

  /** A plugin response (`message`, `actions`, `ui`) to a call the native side made. */
  fun perform(plugin: String, responseJson: String) =
    send("perform", mapOf("plugin" to plugin, "response" to responseJson))

  fun subscriptions(patterns: List<String>) = send("subscriptions", mapOf("patterns" to patterns), queueable = false)

  fun contentHeight(viewId: Int, height: Double) =
    send("contentHeight", mapOf("viewId" to viewId, "height" to height))

  /** True while native code listens for video sessions: Dart then registers every player natively right away. */
  fun videoSessionsWanted(wanted: Boolean) = send("videoSessions", mapOf("wanted" to wanted), queueable = false)

  private fun send(method: String, args: Map<String, Any?>, queueable: Boolean = true) {
    PluginRuntime.runOnMain {
      val target = channel
      if (target != null && dartReady) {
        target.invokeMethod(method, args)
      } else if (queueable) {
        synchronized(queue) {
          if (queue.size >= MAX_QUEUE) {
            queue.removeFirst()
          }
          queue.addLast(method to args)
        }
      }
    }
  }

  private fun flush() {
    val target = channel ?: return
    val pending = synchronized(queue) { queue.toList().also { queue.clear() } }
    pending.forEach { (method, args) -> target.invokeMethod(method, args) }
  }

  private fun info(): Map<String, Any?> = mapOf(
    "apiVersion" to PluginRuntime.API_VERSION,
    "features" to PluginRuntime.FEATURES.sorted(),
    "functions" to PluginHostFunctions.describe(),
    "plugins" to PluginRuntime.loadedPlugins(),
  )

  // ---- Dart to native -------------------------------------------------------------------------------------------

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      handle(call, result)
    } catch (error: Throwable) {
      Log.e(PluginRuntime.TAG, "immich/plugin_native ${call.method} failed", error)
      result.error("native_error", error.message ?: error.toString(), null)
    }
  }

  private fun handle(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "attach" -> {
        dartReady = true
        result.success(info())
        PluginRuntime.mainHandler.post {
          flush()
          channel?.invokeMethod("subscriptions", mapOf("patterns" to PluginEvents.patterns()))
          channel?.invokeMethod("videoSessions", mapOf("wanted" to PluginVideoSessions.wanted))
        }
      }

      "detach" -> {
        dartReady = false
        result.success(null)
      }

      "info" -> result.success(info())

      "call" -> {
        val plugin = call.argument<String>("plugin") ?: ""
        val name = call.argument<String>("name") ?: throw IllegalArgumentException("name is required")
        val args = call.argument<String>("args") ?: "[]"
        PluginHostFunctions.callAsync(plugin, name, args) { envelope ->
          PluginRuntime.runOnMain { result.success(envelope) }
        }
      }

      "functions" -> result.success(PluginHostFunctions.describe())

      "dispatchEvent" -> {
        val event = call.argument<String>("event") ?: throw IllegalArgumentException("event is required")
        PluginEvents.dispatchFromDart(event, call.argument<String>("data") ?: "{}")
        result.success(null)
      }

      "setTheme" -> {
        PluginViews.setTheme(call.argument<String>("theme") ?: "{}")
        result.success(null)
      }

      "taskShow" -> {
        PluginNotifications.showTask(
          PluginRuntime.context,
          id = call.argument<String>("id") ?: throw IllegalArgumentException("id is required"),
          plugin = call.argument<String>("plugin"),
          title = call.argument<String>("title") ?: "",
          text = call.argument<String>("text"),
          progress = call.argument<Number>("progress")?.toDouble(),
          cancellable = call.argument<Boolean>("cancellable") ?: false,
        )
        result.success(null)
      }

      "taskFinish" -> {
        PluginNotifications.finishTask(
          PluginRuntime.context,
          id = call.argument<String>("id") ?: throw IllegalArgumentException("id is required"),
          title = call.argument<String>("title"),
          text = call.argument<String>("text"),
          success = call.argument<Boolean>("success") ?: true,
          keep = call.argument<Boolean>("keep") ?: false,
        )
        result.success(null)
      }

      "taskCancel" -> {
        PluginNotifications.cancelTask(
          PluginRuntime.context,
          call.argument<String>("id") ?: throw IllegalArgumentException("id is required"),
        )
        result.success(null)
      }

      else -> result.notImplemented()
    }
  }
}
