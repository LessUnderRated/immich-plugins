package app.alextran.immich.plugins.api

import android.app.Activity
import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.res.Configuration
import android.os.Bundle
import android.view.View
import java.io.File

/**
 * Native capabilities of one plugin, obtained with `ImmichNative.of(host)`. Everything registered through it is owned
 * by the plugin and removed when the plugin is unloaded. Callbacks run on the main thread unless stated otherwise;
 * an exception thrown by plugin code in a callback is logged and reported, never crashes the app.
 */
interface NativeHost {
  /** Native API version of the running app ([ImmichNative.API_VERSION] of the app). */
  val apiVersion: Int

  /** Feature flags, see docs/plugins/native.md. */
  val features: Set<String>

  fun hasFeature(feature: String): Boolean

  val pluginName: String

  /** Application context. */
  val context: Context

  /** The activity in front (the app's main activity while the app is open), or null. */
  val activity: Activity?

  /** `io.flutter.plugin.common.BinaryMessenger` of the app's Flutter engine, or null while no engine runs. */
  val binaryMessenger: Any?

  /** `io.flutter.embedding.engine.FlutterEngine` of the app, or null while no engine runs. */
  val flutterEngine: Any?

  val events: NativeEvents
  val lifecycle: NativeLifecycle
  val intents: NativeIntents
  val permissions: NativePermissions
  val activityResults: NativeActivityResults
  val notifications: NativeNotifications
  val work: NativeWork
  val media: NativeMedia
  val video: NativeVideo
  val views: NativeViews
  val plugins: NativePlugins
  val hostFunctions: NativeHostFunctions

  /** Writes to the app log (Settings > Logs). [level]: `fine`, `info`, `warning` or `severe`. */
  fun log(level: String, message: String, error: Throwable?)

  /**
   * Load this plugin natively when the app's main activity starts, before the launch intent is handled and before
   * Flutter starts, so its [IntentInterceptor]s and [LifecycleListener]s see the launch. Persisted.
   */
  fun setLoadOnStartup(enabled: Boolean)

  /** Runs [block] now, reporting instead of throwing if it fails. */
  fun runGuarded(where: String, block: Runnable)
}

// ---- events -----------------------------------------------------------------------------------------------------

interface NativeEvents {
  /** Emits an event on the app's plugin event bus (`payloadJson` is a JSON object); the payload gets `source`. */
  fun emit(event: String, payloadJson: String)

  /**
   * Listens in-process. [pattern]: an event name, `prefix.*` or `*`. Receives native events (activity, intent,
   * notification, work, task, permission, plugin errors) and, while the subscription exists, every app event the
   * Dart event bus forwards to native code. Called on the main thread.
   */
  fun addListener(pattern: String, listener: NativeEventListener): Registration
}

fun interface NativeEventListener {
  fun onEvent(event: String, payloadJson: String)
}

// ---- activity lifecycle -----------------------------------------------------------------------------------------

interface NativeLifecycle {
  val currentActivity: Activity?

  /** True while any activity of the app is started (visible). */
  val isForeground: Boolean

  fun addListener(listener: LifecycleListener): Registration
}

/** All methods are optional. Main thread. */
interface LifecycleListener {
  fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}

  fun onActivityStarted(activity: Activity) {}

  fun onActivityResumed(activity: Activity) {}

  fun onActivityPaused(activity: Activity) {}

  fun onActivityStopped(activity: Activity) {}

  fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

  fun onActivityDestroyed(activity: Activity) {}

  fun onWindowFocusChanged(activity: Activity, hasFocus: Boolean) {}

  fun onForegroundChanged(foreground: Boolean) {}

  fun onConfigurationChanged(newConfig: Configuration) {}

  fun onTrimMemory(level: Int) {}
}

// ---- intents ----------------------------------------------------------------------------------------------------

interface NativeIntents {
  /** The last intent the main activity received, after interception. */
  val currentIntent: Intent?

  fun addInterceptor(interceptor: IntentInterceptor): Registration

  /** Higher [priority] runs first; default 0. */
  fun addInterceptor(interceptor: IntentInterceptor, priority: Int): Registration

  /** The JSON shape used by the `intent.received` event. */
  fun toJson(intent: Intent): String
}

fun interface IntentInterceptor {
  /**
   * Called on the main thread for every intent the main activity receives (share, view, deep links, launcher), before
   * the app handles it. [launch] is true for the intent that started the activity. Return [intent] (possibly
   * modified), a replacement, or null to consume it: the app then never sees it.
   */
  fun onIntent(activity: Activity, intent: Intent, launch: Boolean): Intent?
}

// ---- permissions and activity results ---------------------------------------------------------------------------

interface NativePermissions {
  fun isGranted(permission: String): Boolean

  fun shouldShowRationale(permission: String): Boolean

  /**
   * Asks the user for the missing ones (only permissions declared in the app manifest can be granted). [callback]
   * gets every requested permission with its state, on the main thread; all false when no activity is available.
   */
  fun request(permissions: Array<String>, callback: PermissionsCallback)

  /** Opens the app's page in the system settings. */
  fun openAppSettings()
}

fun interface PermissionsCallback {
  fun onResult(results: Map<String, Boolean>)
}

interface NativeActivityResults {
  /** Starts [intent] from the activity in front; [callback] gets the result (RESULT_CANCELED without an activity). */
  fun startActivityForResult(intent: Intent, callback: ActivityResultListener)

  fun startIntentSenderForResult(sender: IntentSender, callback: ActivityResultListener)
}

fun interface ActivityResultListener {
  fun onActivityResult(resultCode: Int, data: Intent?)
}

// ---- notifications ----------------------------------------------------------------------------------------------

interface NativeNotifications {
  /** Notifications are allowed (app setting and, on Android 13+, the POST_NOTIFICATIONS permission). */
  val enabled: Boolean

  /** The app's monochrome notification icon resource. */
  val smallIcon: Int

  /**
   * Creates or updates a channel owned by this plugin. [importance]: `NotificationManager.IMPORTANCE_*`.
   * Returns the Android channel id to use with your own `Notification.Builder`.
   */
  fun createChannel(id: String, name: String, importance: Int, description: String?): String

  fun deleteChannel(id: String)

  /** The Android channel id of this plugin's channel [id] (`default` always exists). */
  fun channelId(id: String): String

  /** Posts a notification described by JSON (same spec as `notify.post`); returns `{ "posted", "id", "reason"? }`. */
  fun post(specJson: String): String

  /** Posts your own notification under this plugin's [id]. */
  fun post(id: String, notification: Notification)

  fun cancel(id: String)

  fun cancelAll()

  /** Ids of this plugin's notifications that are showing. */
  fun active(): List<String>

  /**
   * A PendingIntent for an action button of notification [id]: tapping it calls plugin [method] (type
   * `NotificationActionV1`) and emits `notification.action`. [replyLabel] non-null adds a text reply field.
   */
  fun actionIntent(id: String, actionId: String, method: String?, paramsJson: String?, replyLabel: String?): PendingIntent

  /** A PendingIntent for tapping notification [id]: opens the app if [openApp], calls [method] if set, emits `notification.tapped`. */
  fun contentIntent(id: String, method: String?, paramsJson: String?, openApp: Boolean): PendingIntent
}

// ---- background work --------------------------------------------------------------------------------------------

interface NativeWork {
  /** Schedules a plugin method call that survives the app being closed (same spec as `work.schedule`). */
  fun schedule(specJson: String): String

  fun cancel(id: String)

  fun cancelAll()

  /** JSON array of this plugin's scheduled work. */
  fun list(): String

  /** True once the system stopped run [runId] (the `runId` in `WorkV1` data); poll it in long jobs. */
  fun isStopped(runId: String): Boolean
}

// ---- media ------------------------------------------------------------------------------------------------------

interface NativeMedia {
  /** Adds [source] as a new photo in the device gallery. [optionsJson]: see `saveMedia`. Result `{ id, uri, ... }`. */
  fun saveImage(source: File, optionsJson: String, callback: ResultCallback)

  fun saveVideo(source: File, optionsJson: String, callback: ResultCallback)

  /** Overwrites device asset [assetId] with [source] (asks the user for write access when needed). See `replaceMedia`. */
  fun replace(assetId: String, video: Boolean, source: File, optionsJson: String, callback: ResultCallback)
}

// ---- platform views ---------------------------------------------------------------------------------------------

interface NativeViews {
  /** The app's current theme. */
  val theme: PluginTheme

  fun addThemeListener(listener: ThemeListener): Registration

  /** Tells the app the content height of the inline plugin view containing [view], in pixels. */
  fun setContentHeight(view: View, heightPx: Int)

  /** Measures the plugin view containing [view] after every layout and reports its wrap-content height. */
  fun autoContentHeight(view: View): Registration

  /** Flutter platform view id of the plugin view containing [view], or -1. */
  fun viewId(view: View): Int
}

fun interface ThemeListener {
  fun onThemeChanged(theme: PluginTheme)
}

/**
 * The app theme. [colors] holds the Material colour scheme as ARGB ints by role name (`primary`, `onPrimary`,
 * `primaryContainer`, `surface`, `surfaceContainer`, `onSurface`, `onSurfaceVariant`, `outline`, `error`, ...).
 */
class PluginTheme(
  val isDark: Boolean,
  val colors: Map<String, Int>,
  val fontFamily: String?,
  val textScale: Double,
  /** The theme as JSON: `{ "dark", "colors": { name: argb }, "fontFamily", "textScale" }`. */
  val json: String,
) {
  fun color(name: String): Int? = colors[name]

  fun color(name: String, fallback: Int): Int = colors[name] ?: fallback
}

// ---- other plugins ----------------------------------------------------------------------------------------------

interface NativePlugins {
  /** Names of the plugins loaded in this process. */
  val loaded: List<String>

  fun isLoaded(plugin: String): Boolean

  /**
   * Calls [method] of [plugin] directly, on the calling thread, with input `{ "type": type, "config": {}, "data": data,
   * "caller": thisPlugin }`. Loads the plugin if it is enabled but not loaded. Throws if it fails.
   */
  fun call(plugin: String, method: String, type: String, dataJson: String): String?

  /** Same as [call] on a background thread; [callback] gets an envelope. */
  fun callAsync(plugin: String, method: String, type: String, dataJson: String, callback: ResultCallback)

  /**
   * Shares an object with other plugins under [name] (prefixed with `<thisPlugin>/` unless it already is). Use JDK or
   * Android types (Runnable, java.util.function.Function, Map, ...): plugins have separate class loaders.
   */
  fun registerService(name: String, service: Any): Registration

  /** A service registered by any plugin, by full name (`<plugin>/<name>`). */
  fun service(name: String): Any?

  val services: List<String>
}

// ---- native host functions --------------------------------------------------------------------------------------

interface NativeHostFunctions {
  /**
   * Registers a host function implemented in this plugin, callable by every plugin through `callHost` (fast path,
   * no Dart round trip) and from Dart through `native.call`. [name] must start with `<thisPlugin>.`.
   */
  fun register(name: String, function: NativeHostFunction): Registration

  fun registerAsync(name: String, function: NativeAsyncHostFunction): Registration

  /** Calls a natively implemented host function (built-in or plugin-registered); returns the envelope. */
  fun call(name: String, argsJson: String): String

  fun callAsync(name: String, argsJson: String, callback: ResultCallback)

  fun has(name: String): Boolean

  val names: List<String>
}

/** Returns the response as JSON text (null for `null`); an exception becomes `{ "success": false, "status": 500 }`. */
fun interface NativeHostFunction {
  fun invoke(caller: String, argsJson: String): String?
}

fun interface NativeAsyncHostFunction {
  fun invoke(caller: String, argsJson: String, reply: HostReply)
}

interface HostReply {
  fun success(responseJson: String?)

  fun error(status: Int, message: String)
}
