package app.alextran.immich.plugins

import android.app.Activity
import android.app.Application
import android.content.ComponentCallbacks2
import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.ComponentActivity
import app.alextran.immich.plugins.api.LifecycleListener
import app.alextran.immich.plugins.api.Registration
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Activity and process lifecycle for plugins: forwards every activity callback, configuration and memory changes to
 * native [LifecycleListener]s and as events (`activity.*`, `app.foreground`, `app.background`, `system.*`).
 */
internal object PluginLifecycle : Application.ActivityLifecycleCallbacks, ComponentCallbacks2 {
  private const val MAIN_ACTIVITY = "app.alextran.immich.MainActivity"

  private class Entry(val plugin: String, val listener: LifecycleListener)

  private val listeners = CopyOnWriteArrayList<Entry>()
  private val activities = CopyOnWriteArrayList<WeakReference<Activity>>()

  @Volatile
  private var resumed: WeakReference<Activity>? = null

  @Volatile
  private var main: WeakReference<Activity>? = null

  private var started = 0

  @Volatile
  var isForeground = false
    private set

  fun install(app: Application) {
    app.registerActivityLifecycleCallbacks(this)
    app.registerComponentCallbacks(this)
  }

  private fun Activity.alive(): Activity? = takeUnless { it.isFinishing || it.isDestroyed }

  val currentActivity: Activity?
    get() = resumed?.get()?.alive() ?: main?.get()?.alive()

  val mainActivity: Activity?
    get() = main?.get()?.alive()

  /** The activity to launch permission requests and activity results from. */
  fun resultActivity(): ComponentActivity? =
    (resumed?.get()?.alive() as? ComponentActivity) ?: (main?.get()?.alive() as? ComponentActivity)

  fun isMain(activity: Activity): Boolean = activity.javaClass.name == MAIN_ACTIVITY

  fun state(): JSONObject = JSONObject()
    .put("foreground", isForeground)
    .put("activity", currentActivity?.javaClass?.simpleName)
    .put("resumed", resumed?.get()?.alive()?.javaClass?.simpleName)
    .put("activities", PluginJson.toJson(activities.mapNotNull { it.get()?.alive()?.javaClass?.simpleName }))

  fun addListener(plugin: String, listener: LifecycleListener): Registration {
    val entry = Entry(plugin, listener)
    listeners.add(entry)
    return PluginRuntime.scope(plugin).track { listeners.remove(entry) }
  }

  private inline fun dispatch(what: String, crossinline block: (LifecycleListener) -> Unit) {
    for (entry in listeners) {
      PluginCrashGuard.run(entry.plugin, "lifecycle $what") { block(entry.listener) }
    }
  }

  private fun event(name: String, activity: Activity) {
    PluginEvents.emit(
      name,
      JSONObject()
        .put("activity", activity.javaClass.simpleName)
        .put("class", activity.javaClass.name)
        .put("main", isMain(activity)),
    )
  }

  override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
    if (isMain(activity)) {
      main = WeakReference(activity)
    }
    activities.removeIf { it.get() == null || it.get() === activity }
    activities.add(WeakReference(activity))
    dispatch("created") { it.onActivityCreated(activity, savedInstanceState) }
    event("activity.created", activity)
  }

  override fun onActivityStarted(activity: Activity) {
    started++
    if (started == 1 && !isForeground) {
      isForeground = true
      dispatch("foreground") { it.onForegroundChanged(true) }
      PluginEvents.emit("app.foreground", JSONObject())
    }
    dispatch("started") { it.onActivityStarted(activity) }
    event("activity.started", activity)
  }

  override fun onActivityResumed(activity: Activity) {
    resumed = WeakReference(activity)
    dispatch("resumed") { it.onActivityResumed(activity) }
    event("activity.resumed", activity)
  }

  override fun onActivityPaused(activity: Activity) {
    if (resumed?.get() === activity) {
      resumed = null
    }
    dispatch("paused") { it.onActivityPaused(activity) }
    event("activity.paused", activity)
  }

  override fun onActivityStopped(activity: Activity) {
    started = (started - 1).coerceAtLeast(0)
    dispatch("stopped") { it.onActivityStopped(activity) }
    event("activity.stopped", activity)
    if (started == 0 && isForeground && !activity.isChangingConfigurations) {
      isForeground = false
      dispatch("background") { it.onForegroundChanged(false) }
      PluginEvents.emit("app.background", JSONObject())
    }
  }

  override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {
    dispatch("saveInstanceState") { it.onActivitySaveInstanceState(activity, outState) }
  }

  override fun onActivityDestroyed(activity: Activity) {
    activities.removeIf { it.get() == null || it.get() === activity }
    if (main?.get() === activity) {
      main = null
    }
    PluginActivityResults.onActivityDestroyed(activity)
    dispatch("destroyed") { it.onActivityDestroyed(activity) }
    event("activity.destroyed", activity)
  }

  /** Called from `MainActivity.onWindowFocusChanged`. */
  @JvmStatic
  fun onWindowFocusChanged(activity: Activity, hasFocus: Boolean) {
    dispatch("windowFocus") { it.onWindowFocusChanged(activity, hasFocus) }
    PluginEvents.emit(
      "activity.focusChanged",
      JSONObject().put("activity", activity.javaClass.simpleName).put("main", isMain(activity)).put("focused", hasFocus),
    )
  }

  override fun onConfigurationChanged(newConfig: Configuration) {
    dispatch("configuration") { it.onConfigurationChanged(newConfig) }
    val night = newConfig.uiMode and Configuration.UI_MODE_NIGHT_MASK
    PluginEvents.emit(
      "system.configurationChanged",
      JSONObject()
        .put("dark", night == Configuration.UI_MODE_NIGHT_YES)
        .put("orientation", if (newConfig.orientation == Configuration.ORIENTATION_LANDSCAPE) "landscape" else "portrait")
        .put("locale", newConfig.locales.get(0)?.toLanguageTag())
        .put("fontScale", newConfig.fontScale.toDouble())
        .put("densityDpi", newConfig.densityDpi)
        .put("screenWidthDp", newConfig.screenWidthDp)
        .put("screenHeightDp", newConfig.screenHeightDp),
    )
  }

  override fun onTrimMemory(level: Int) {
    dispatch("trimMemory") { it.onTrimMemory(level) }
    PluginEvents.emit("system.trimMemory", JSONObject().put("level", level))
  }

  @Deprecated("Deprecated in Android")
  override fun onLowMemory() {
    PluginEvents.emit("system.lowMemory", JSONObject())
  }
}
