package app.alextran.immich.plugins

import android.os.Build
import app.alextran.immich.plugins.PluginJson.str
import app.alextran.immich.plugins.api.HostReply
import app.alextran.immich.plugins.api.NativeAsyncHostFunction
import app.alextran.immich.plugins.api.NativeHostFunction
import app.alextran.immich.plugins.api.Registration
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Host functions implemented natively: answered in-process without a Dart round trip (`callHost` fast path), and
 * callable from Dart through the `immich/plugin_native` channel (`call`). Built-ins cover `native.*`, `activity.*`,
 * `intent.*`, `permissions.*`, `notify.*` and `work.*`; plugins add their own under `<plugin>.*`.
 */
internal object PluginHostFunctions {
  private class Entry(
    val owner: String?,
    val name: String,
    val doc: String?,
    val sync: NativeHostFunction?,
    val async: NativeAsyncHostFunction?,
  )

  private val functions = ConcurrentHashMap<String, Entry>()
  private const val SYNC_TIMEOUT_SECONDS = 300L

  @Volatile
  private var builtinsRegistered = false

  fun has(name: String): Boolean = functions.containsKey(name)

  fun names(): List<String> = functions.keys.sorted()

  fun describe(): List<Map<String, Any?>> = functions.values.sortedBy { it.name }.map {
    mapOf("name" to it.name, "owner" to it.owner, "doc" to it.doc, "async" to (it.async != null))
  }

  // ---- registration ---------------------------------------------------------------------------------------------

  fun register(owner: String, name: String, sync: NativeHostFunction?, async: NativeAsyncHostFunction?): Registration {
    require(name.startsWith("$owner.") && name.length > owner.length + 1) { "Native host function names must start with \"$owner.\"" }
    val function = Entry(owner, name, null, sync, async)
    check(functions.putIfAbsent(name, function) == null) { "Host function $name already exists" }
    return PluginRuntime.scope(owner).track { functions.remove(name, function) }
  }

  fun removeOwner(owner: String) {
    functions.values.removeIf { it.owner == owner }
  }

  private fun builtin(name: String, doc: String, handler: (caller: String, args: JSONArray) -> Any?) {
    functions[name] = Entry(null, name, doc, { caller, argsJson -> PluginJson.stringify(handler(caller, PluginJson.array(argsJson))) }, null)
  }

  private fun builtinAsync(name: String, doc: String, handler: (caller: String, args: JSONArray, reply: (Any?) -> Unit) -> Unit) {
    functions[name] = Entry(null, name, doc, null) { caller, argsJson, reply ->
      handler(caller, PluginJson.array(argsJson)) { value -> reply.success(PluginJson.stringify(value)) }
    }
  }

  // ---- calls ----------------------------------------------------------------------------------------------------

  /** The envelope if [name] is implemented natively, otherwise null (the caller falls back to Dart). */
  fun tryCall(caller: String, name: String, argsJson: String): String? {
    if (!functions.containsKey(name)) {
      return null
    }
    return call(caller, name, argsJson)
  }

  /** Blocking call. Asynchronous functions cannot be waited for on the main thread (409: use callHostAsync). */
  fun call(caller: String, name: String, argsJson: String): String {
    val function = functions[name] ?: return PluginJson.error(501, "Host function $name is not implemented natively")
    if (function.sync != null) {
      return invokeSync(function, caller, argsJson)
    }
    if (PluginRuntime.isMainThread) {
      return PluginJson.error(409, "Host function $name is asynchronous; call it with callHostAsync on the main thread")
    }
    val latch = CountDownLatch(1)
    var envelope: String? = null
    invokeAsync(function, caller, argsJson) {
      envelope = it
      latch.countDown()
    }
    if (!latch.await(SYNC_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
      return PluginJson.error(504, "Host function $name timed out")
    }
    return envelope ?: PluginJson.error(500, "Host function $name returned nothing")
  }

  /** Non-blocking call; [callback] gets the envelope (on a background thread for synchronous functions). */
  fun callAsync(caller: String, name: String, argsJson: String, callback: (String) -> Unit) {
    val function = functions[name]
    if (function == null) {
      callback(PluginJson.error(501, "Host function $name is not implemented natively"))
      return
    }
    if (function.sync != null) {
      PluginRuntime.executor.execute { callback(invokeSync(function, caller, argsJson)) }
    } else {
      invokeAsync(function, caller, argsJson, callback)
    }
  }

  private fun invokeSync(function: Entry, caller: String, argsJson: String): String = try {
    PluginJson.ok(function.sync!!.invoke(caller, argsJson))
  } catch (error: IllegalArgumentException) {
    PluginJson.error(400, error.message ?: error.toString())
  } catch (error: SecurityException) {
    PluginJson.error(403, error.message ?: error.toString())
  } catch (error: Throwable) {
    function.owner?.let { PluginCrashGuard.report(it, "host function ${function.name}", error) }
    PluginJson.error(500, error.message ?: error.toString())
  }

  private fun invokeAsync(function: Entry, caller: String, argsJson: String, callback: (String) -> Unit) {
    val answered = AtomicBoolean(false)
    val reply = object : HostReply {
      override fun success(responseJson: String?) {
        if (answered.compareAndSet(false, true)) {
          callback(PluginJson.ok(responseJson))
        }
      }

      override fun error(status: Int, message: String) {
        if (answered.compareAndSet(false, true)) {
          callback(PluginJson.error(status, message))
        }
      }
    }
    try {
      function.async!!.invoke(caller, argsJson, reply)
    } catch (error: IllegalArgumentException) {
      reply.error(400, error.message ?: error.toString())
    } catch (error: Throwable) {
      function.owner?.let { PluginCrashGuard.report(it, "host function ${function.name}", error) }
      reply.error(500, error.message ?: error.toString())
    }
  }

  // ---- built-ins ------------------------------------------------------------------------------------------------

  private fun JSONArray.objectAt(index: Int, what: String): JSONObject =
    optJSONObject(index) ?: throw IllegalArgumentException("Argument ${index + 1} must be $what")

  private fun JSONArray.stringAt(index: Int, what: String): String =
    str(index)?.takeIf { it.isNotEmpty() } ?: throw IllegalArgumentException("Argument ${index + 1} must be $what")

  private fun JSONArray.stringsAt(index: Int): List<String> = when (val value = opt(index)) {
    is JSONArray -> List(value.length()) { value.optString(it) }.filter { it.isNotEmpty() }
    is String -> listOf(value)
    else -> throw IllegalArgumentException("Argument ${index + 1} must be a permission name or a list of them")
  }

  fun registerBuiltins() {
    if (builtinsRegistered) {
      return
    }
    builtinsRegistered = true
    val context = { PluginRuntime.context }

    builtin("native.info", "[] -> { apiVersion, features, sdkInt, release, manufacturer, model, abis, packageName, foreground, plugins }") { _, _ ->
      mapOf(
        "apiVersion" to PluginRuntime.API_VERSION,
        "features" to PluginRuntime.FEATURES.sorted(),
        "sdkInt" to Build.VERSION.SDK_INT,
        "release" to Build.VERSION.RELEASE,
        "manufacturer" to Build.MANUFACTURER,
        "model" to Build.MODEL,
        "abis" to Build.SUPPORTED_ABIS.toList(),
        "packageName" to context().packageName,
        "foreground" to PluginLifecycle.isForeground,
        "plugins" to PluginRuntime.loadedPlugins(),
      )
    }
    builtin("native.functions", "[] -> [{ name, owner, doc, async }]") { _, _ -> describe() }
    functions["native.call"] = Entry(null, "native.call", "[name, args[]] -> the result of a natively implemented host function", null) { caller, argsJson, reply ->
      val args = PluginJson.array(argsJson)
      val name = args.stringAt(0, "a host function name")
      callAsync(caller, name, (args.optJSONArray(1) ?: JSONArray()).toString()) { envelope ->
        val json = PluginJson.obj(envelope)
        if (json.optBoolean("success", false)) {
          reply.success(PluginJson.stringify(json.opt("response")))
        } else {
          reply.error(json.optInt("status", 500), json.optString("message", "Host function $name failed"))
        }
      }
    }
    builtin("native.services", "[] -> [service names]") { _, _ -> PluginServices.names() }

    builtin("activity.state", "[] -> { foreground, activity, resumed, activities }") { _, _ -> PluginLifecycle.state() }
    builtin("intent.current", "[] -> the current intent of the main activity as in intent.received, or null") { _, _ ->
      PluginIntents.currentIntent?.let { PluginIntents.toJson(it) }
    }

    builtin("permissions.check", "[name | [names]] -> { name: granted }") { _, args ->
      args.stringsAt(0).associateWith { PluginActivityResults.isGranted(it) }
    }
    builtin("permissions.shouldShowRationale", "[name] -> bool") { _, args ->
      PluginActivityResults.shouldShowRationale(args.stringAt(0, "a permission name"))
    }
    builtinAsync("permissions.request", "[name | [names]] -> { name: granted } (asks the user)") { caller, args, reply ->
      PluginActivityResults.requestPermissions(caller, args.stringsAt(0)) { results -> reply(results) }
    }
    builtin("permissions.openSettings", "[] -> null (opens the app's system settings page)") { _, _ ->
      PluginActivityResults.openAppSettings()
      null
    }

    builtin("notify.enabled", "[] -> bool") { _, _ -> PluginNotifications.enabled(context()) }
    builtin("notify.createChannel", "[{ id, name, importance: none|min|low|default|high|max, description }] -> { channel }") { caller, args ->
      val spec = args.objectAt(0, "a channel object")
      val id = spec.str("id") ?: throw IllegalArgumentException("channel id is required")
      val channel = PluginNotifications.createChannel(
        context(),
        caller,
        id,
        spec.str("name") ?: id,
        PluginNotifications.importance(spec.str("importance")),
        spec.str("description"),
      )
      mapOf("channel" to channel)
    }
    builtin("notify.deleteChannel", "[id] -> null") { caller, args ->
      PluginNotifications.deleteChannel(context(), caller, args.stringAt(0, "a channel id"))
      null
    }
    builtin("notify.post", "[spec] -> { posted, id, reason? }") { caller, args ->
      PluginNotifications.post(context(), caller, args.objectAt(0, "a notification object"))
    }
    builtin("notify.cancel", "[id] -> null") { caller, args ->
      PluginNotifications.cancel(context(), caller, args.stringAt(0, "a notification id"))
      null
    }
    builtin("notify.cancelAll", "[] -> null") { caller, _ ->
      PluginNotifications.cancelAll(context(), caller)
      null
    }
    builtin("notify.active", "[] -> [ids]") { caller, _ -> PluginNotifications.active(context(), caller) }

    builtin("work.schedule", "[spec] -> { id, workId, periodic }") { caller, args ->
      PluginBackgroundWork.schedule(context(), caller, args.objectAt(0, "a work object"))
    }
    builtin("work.cancel", "[id] -> null") { caller, args ->
      PluginBackgroundWork.cancel(context(), caller, args.stringAt(0, "a work id"))
      null
    }
    builtin("work.cancelAll", "[] -> null") { caller, _ ->
      PluginBackgroundWork.cancelAll(context(), caller)
      null
    }
    builtin("work.list", "[] -> [{ id, workId, state, runAttempt, running }]") { caller, _ ->
      PluginBackgroundWork.list(context(), caller)
    }
    builtin("work.isStopped", "[runId] -> bool") { _, args ->
      PluginBackgroundWork.isStopped(args.stringAt(0, "a run id"))
    }
  }
}
