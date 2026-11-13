package app.alextran.immich.plugins

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import app.alextran.immich.plugins.api.ImmichNative
import app.alextran.immich.plugins.api.ImmichPlugin
import app.alextran.immich.plugins.api.ImmichPluginLifecycle
import app.alextran.immich.plugins.api.PluginHost
import io.flutter.embedding.engine.FlutterEngine
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Supplies the real [PluginHost] of a plugin while the app's plugin host (DexPluginHost) runs. */
fun interface PluginHostFactory {
  fun hostFor(plugin: String): PluginHost
}

/**
 * Process-wide native plugin runtime: loaded plugin instances, per-plugin native hosts and scopes, the Flutter
 * engine, and the wiring between the native capabilities (lifecycle, intents, permissions, notifications, work,
 * media, video sessions, views, host functions).
 *
 * Wiring (see docs/plugins/native.md, "App integration"):
 * - `ImmichApp.onCreate`: [init].
 * - `MainActivity.onCreate` before `super.onCreate`: [onMainActivityCreate].
 * - `MainActivity.onNewIntent`: [PluginIntents.processNew]; `onWindowFocusChanged`: [PluginLifecycle.onWindowFocusChanged].
 * - `MainActivity.configureFlutterEngine` / `cleanUpFlutterEngine`: [attachEngine] / [detachEngine].
 * - `DexPluginHost`: [load], [unload], [plugin], [setHostFactory], [PluginHostFunctions.tryCall] in `callHost`,
 *   [PluginViews.wrap] for platform views, [PluginCrashGuard] around plugin code.
 */
object PluginRuntime {
  const val TAG = "ImmichPlugins"
  const val API_VERSION = ImmichNative.API_VERSION

  val FEATURES: Set<String> = setOf(
    "events",
    "lifecycle",
    "intents",
    "intents.intercept",
    "permissions",
    "activityResults",
    "notifications",
    "notifications.actions",
    "tasks.notification",
    "work",
    "work.foreground",
    "media.save",
    "media.replace",
    "video.sessions",
    "video.capture",
    "video.overlay",
    "views.theme",
    "views.contentHeight",
    "views.isolation",
    "hostFunctions",
    "plugins.call",
    "plugins.services",
    "flutter.messenger",
    "crashIsolation",
    "startupLoad",
  )

  @Volatile
  private var application: Application? = null

  val isInitialized: Boolean get() = application != null

  val context: Context
    get() = application ?: throw IllegalStateException("PluginRuntime.init was not called")

  val mainHandler = Handler(Looper.getMainLooper())

  val executor: ExecutorService = Executors.newCachedThreadPool { runnable ->
    Thread(runnable, "plugin-native").apply { isDaemon = true }
  }

  @Volatile
  var engine: FlutterEngine? = null
    private set

  @Volatile
  private var hostFactory: PluginHostFactory? = null

  private class LoadedPlugin(
    val plugin: ImmichPlugin,
    val loader: ClassLoader?,
    val signature: String?,
  )

  private val loaded = ConcurrentHashMap<String, LoadedPlugin>()
  private val nativeHosts = ConcurrentHashMap<String, NativeHostImpl>()
  private val scopes = ConcurrentHashMap<String, PluginScope>()
  private val loadLock = Any()

  // ---- process and engine ---------------------------------------------------------------------------------------

  /** Called from `ImmichApp.onCreate`; safe to call again. */
  @JvmStatic
  fun init(app: Application) {
    synchronized(this) {
      if (application != null) {
        return
      }
      application = app
    }
    PluginLifecycle.install(app)
    PluginHostFunctions.registerBuiltins()
  }

  /** For entry points that may run before `ImmichApp.onCreate` finished (receivers, workers). */
  fun ensureInit(context: Context) {
    if (application == null) {
      (context.applicationContext as? Application)?.let { init(it) }
    }
  }

  /** Called from `MainActivity.onCreate` before `super.onCreate`. */
  @JvmStatic
  fun onMainActivityCreate(activity: Activity, savedInstanceState: Bundle?) {
    ensureInit(activity)
    loadStartupPlugins()
    if (savedInstanceState == null) {
      PluginIntents.processLaunch(activity)
    }
  }

  /** Called from `MainActivity.configureFlutterEngine`. */
  @JvmStatic
  fun attachEngine(engine: FlutterEngine, activity: Activity) {
    ensureInit(activity)
    this.engine = engine
    PluginNativeBridge.attach(engine.dartExecutor.binaryMessenger)
    PluginVideoSessions.attach(engine)
  }

  /** Called from `MainActivity.cleanUpFlutterEngine`. */
  @JvmStatic
  fun detachEngine(engine: FlutterEngine) {
    if (this.engine !== engine) {
      return
    }
    PluginVideoSessions.detach()
    PluginNativeBridge.detach()
    this.engine = null
  }

  /** Set by DexPluginHost so native components use the real host (with Dart host functions) while it runs. */
  @JvmStatic
  fun setHostFactory(factory: PluginHostFactory?) {
    hostFactory = factory
  }

  /** The host of [plugin]: the app's plugin host while it runs, otherwise a headless host (native functions only). */
  fun host(plugin: String): PluginHost =
    hostFactory?.hostFor(plugin) ?: HeadlessPluginHost(context, plugin, PluginRegistryStore.get(context, plugin)?.dexPath)

  // ---- plugins --------------------------------------------------------------------------------------------------

  /**
   * Loads (or returns the already loaded instance of) plugin [name]. Records it for background loads, installs crash
   * isolation and calls [ImmichPluginLifecycle.onLoad].
   */
  @JvmStatic
  fun load(name: String, dexPath: String, entry: String): ImmichPlugin {
    val source = File(dexPath)
    val signature = "${source.lastModified()}-${source.length()}:$entry"
    val plugin: ImmichPlugin
    synchronized(loadLock) {
      val existing = loaded[name]
      if (existing != null && existing.signature == signature) {
        PluginRegistryStore.put(context, name, dexPath, entry)
        return existing.plugin
      }
      if (existing != null) {
        unload(name)
      }
      val result = PluginLoader.instantiate(context, name, source, entry)
      plugin = result.plugin
      loaded[name] = LoadedPlugin(plugin, result.loader, signature)
      PluginRegistryStore.put(context, name, dexPath, entry)
      PluginCrashGuard.registerLoader(name, result.loader)
    }
    PluginCrashGuard.install()
    (plugin as? ImmichPluginLifecycle)?.let { lifecycle ->
      PluginCrashGuard.run(name, "onLoad") { lifecycle.onLoad(host(name)) }
    }
    return plugin
  }

  /** Registers an instance created elsewhere (the app's plugin host) so native capabilities can reach it. */
  @JvmStatic
  fun register(name: String, plugin: ImmichPlugin, dexPath: String?, entry: String?) {
    synchronized(loadLock) {
      loaded[name] = LoadedPlugin(plugin, plugin.javaClass.classLoader, null)
      if (dexPath != null && entry != null) {
        PluginRegistryStore.put(context, name, dexPath, entry)
      }
      plugin.javaClass.classLoader?.let { PluginCrashGuard.registerLoader(name, it) }
    }
    PluginCrashGuard.install()
    (plugin as? ImmichPluginLifecycle)?.let { lifecycle ->
      PluginCrashGuard.run(name, "onLoad") { lifecycle.onLoad(host(name)) }
    }
  }

  /** Unloads [name]: calls [ImmichPluginLifecycle.onUnload] and removes everything it registered natively. */
  @JvmStatic
  fun unload(name: String) {
    val entry = synchronized(loadLock) { loaded.remove(name) }
    if (entry != null) {
      (entry.plugin as? ImmichPluginLifecycle)?.let { lifecycle ->
        PluginCrashGuard.run(name, "onUnload") { lifecycle.onUnload(host(name)) }
      }
    }
    scopes.remove(name)?.clear()
    nativeHosts.remove(name)
    PluginVideoSessions.removePlugin(name)
    PluginHostFunctions.removeOwner(name)
    PluginCrashGuard.unregisterLoader(name)
    if (isInitialized) {
      PluginRegistryStore.setEnabled(context, name, false)
    }
  }

  @JvmStatic
  fun plugin(name: String): ImmichPlugin? = loaded[name]?.plugin

  @JvmStatic
  fun loadedPlugins(): List<String> = loaded.keys.sorted()

  /** The loaded instance, or a native load from the persisted record when the plugin is enabled. */
  @JvmStatic
  fun ensureLoaded(name: String): ImmichPlugin? {
    plugin(name)?.let { return it }
    val record = PluginRegistryStore.get(context, name) ?: return null
    if (!record.enabled || !File(record.dexPath).isFile) {
      return null
    }
    return try {
      load(name, record.dexPath, record.entry)
    } catch (error: Throwable) {
      PluginCrashGuard.report(name, "native load", error)
      null
    }
  }

  /** Loads the plugins that asked for it with `setLoadOnStartup(true)`. */
  @JvmStatic
  fun loadStartupPlugins() {
    for (record in PluginRegistryStore.all(context)) {
      if (record.enabled && record.startup && plugin(record.name) == null) {
        ensureLoaded(record.name)
      }
    }
  }

  fun setLoadOnStartup(name: String, enabled: Boolean) {
    PluginRegistryStore.setStartup(context, name, enabled)
  }

  /**
   * Calls [method] of [target] on the calling thread. [inputJson] is the full call input. Throws when the plugin is
   * not available or fails.
   */
  fun callPlugin(target: String, method: String, inputJson: String): String? {
    val instance = ensureLoaded(target) ?: throw IllegalStateException("Plugin $target is not loaded")
    return try {
      instance.call(method, inputJson, host(target))
    } catch (error: Throwable) {
      PluginCrashGuard.report(target, "call $method", error)
      throw error
    }
  }

  /** Builds the standard call input `{ type, config, data }` plus extra fields. */
  fun callInput(type: String, data: Any?, extra: Map<String, Any?> = emptyMap()): String {
    val json = JSONObject().put("type", type).put("config", JSONObject()).put("data", PluginJson.toJson(data))
    extra.forEach { (key, value) -> json.put(key, PluginJson.toJson(value)) }
    return json.toString()
  }

  fun nativeHost(name: String): NativeHostImpl = nativeHosts.getOrPut(name) { NativeHostImpl(name) }

  internal fun scope(name: String): PluginScope = scopes.getOrPut(name) { PluginScope(name) }

  // ---- threads --------------------------------------------------------------------------------------------------

  val isMainThread: Boolean get() = Looper.myLooper() == Looper.getMainLooper()

  fun runOnMain(block: () -> Unit) {
    if (isMainThread) {
      block()
    } else {
      mainHandler.post(block)
    }
  }

  fun log(level: Int, message: String, error: Throwable? = null) {
    Log.println(level, TAG, if (error == null) message else "$message\n${Log.getStackTraceString(error)}")
  }
}
