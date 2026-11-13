package app.alextran.immich.plugins

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import app.alextran.immich.plugins.api.IntentInterceptor
import app.alextran.immich.plugins.api.Registration
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Incoming intents of the main activity (launch, share, view, deep links): plugin [IntentInterceptor]s may modify,
 * replace or consume each one before the app sees it; every intent is reported as `intent.received`.
 * Notification taps of plugin notifications are handled here and never reach the app.
 */
internal object PluginIntents {
  private class Entry(val plugin: String, val priority: Int, val interceptor: IntentInterceptor)

  private val interceptors = CopyOnWriteArrayList<Entry>()

  @Volatile
  var currentIntent: Intent? = null
    private set

  fun addInterceptor(plugin: String, interceptor: IntentInterceptor, priority: Int): Registration {
    val entry = Entry(plugin, priority, interceptor)
    interceptors.add(entry)
    return PluginRuntime.scope(plugin).track { interceptors.remove(entry) }
  }

  /** `MainActivity.onCreate` (through [PluginRuntime.onMainActivityCreate]): processes and replaces `activity.intent`. */
  @JvmStatic
  fun processLaunch(activity: Activity) {
    val original = activity.intent ?: return
    val processed = process(activity, original, launch = true)
    if (processed == null) {
      activity.intent = Intent(Intent.ACTION_MAIN)
        .addCategory(Intent.CATEGORY_LAUNCHER)
        .setClassName(activity, activity.javaClass.name)
    } else if (processed !== original) {
      activity.intent = processed
    }
  }

  /**
   * `MainActivity.onNewIntent`: returns the intent to hand to `super.onNewIntent` and `setIntent`, or null when it was
   * consumed (then skip both).
   */
  @JvmStatic
  fun processNew(activity: Activity, intent: Intent): Intent? = process(activity, intent, launch = false)

  fun process(activity: Activity, intent: Intent, launch: Boolean): Intent? {
    if (PluginNotifications.handleTapIntent(intent)) {
      return null
    }
    var current = intent
    var consumedBy: String? = null
    for (entry in interceptors.sortedByDescending { it.priority }) {
      val next = PluginCrashGuard.call(entry.plugin, "intent interceptor", current) {
        entry.interceptor.onIntent(activity, current, launch)
      }
      if (next == null) {
        consumedBy = entry.plugin
        break
      }
      current = next
    }
    if (consumedBy == null) {
      currentIntent = current
    }
    val payload = toJson(current)
      .put("launch", launch)
      .put("consumed", consumedBy != null)
      .put("consumedBy", consumedBy)
      .put("modified", current !== intent)
    PluginEvents.emit("intent.received", payload)
    return if (consumedBy == null) current else null
  }

  fun toJson(intent: Intent): JSONObject {
    val json = JSONObject()
      .put("action", intent.action)
      .put("data", intent.dataString)
      .put("type", intent.type)
      .put("package", intent.`package`)
      .put("component", intent.component?.flattenToShortString())
      .put("flags", intent.flags)
      .put("categories", JSONArray(intent.categories?.toList() ?: emptyList<String>()))
      .put("extras", bundleToJson(intent.extras))
    val uris = JSONArray()
    intent.clipData?.let { clip ->
      for (index in 0 until clip.itemCount) {
        val item = clip.getItemAt(index)
        item.uri?.let { uris.put(it.toString()) }
      }
    }
    streams(intent).forEach { uri ->
      val text = uri.toString()
      if ((0 until uris.length()).none { uris.optString(it) == text }) {
        uris.put(text)
      }
    }
    json.put("uris", uris)
    intent.getStringExtra(Intent.EXTRA_TEXT)?.let { json.put("text", it) }
    return json
  }

  @Suppress("DEPRECATION")
  private fun streams(intent: Intent): List<Uri> = try {
    when (val value = intent.extras?.get(Intent.EXTRA_STREAM)) {
      is Uri -> listOf(value)
      is ArrayList<*> -> value.filterIsInstance<Uri>()
      else -> emptyList()
    }
  } catch (_: Throwable) {
    emptyList()
  }

  @Suppress("DEPRECATION")
  fun bundleToJson(bundle: Bundle?): JSONObject {
    val json = JSONObject()
    if (bundle == null) {
      return json
    }
    try {
      for (key in bundle.keySet()) {
        json.put(key, bundleValue(bundle.get(key)))
      }
    } catch (_: Throwable) {
      // Unparcelling a foreign Parcelable can fail; report what was read so far.
    }
    return json
  }

  private fun bundleValue(value: Any?): Any = when (value) {
    null -> JSONObject.NULL
    is String, is Boolean, is Int, is Long, is Double -> value
    is Float -> value.toDouble()
    is Short -> value.toInt()
    is Byte -> value.toInt()
    is Char -> value.toString()
    is CharSequence -> value.toString()
    is Uri -> value.toString()
    is Bundle -> bundleToJson(value)
    is Array<*> -> JSONArray().also { array -> value.forEach { array.put(bundleValue(it)) } }
    is Iterable<*> -> JSONArray().also { array -> value.forEach { array.put(bundleValue(it)) } }
    is IntArray -> JSONArray().also { array -> value.forEach { array.put(it) } }
    is LongArray -> JSONArray().also { array -> value.forEach { array.put(it) } }
    is BooleanArray -> JSONArray().also { array -> value.forEach { array.put(it) } }
    is DoubleArray -> JSONArray().also { array -> value.forEach { array.put(it) } }
    is FloatArray -> JSONArray().also { array -> value.forEach { array.put(it.toDouble()) } }
    else -> value.toString()
  }
}
