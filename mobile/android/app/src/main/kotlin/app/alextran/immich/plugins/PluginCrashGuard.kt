package app.alextran.immich.plugins

import android.os.Looper
import android.util.Log
import org.json.JSONObject
import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.ConcurrentHashMap
import kotlin.system.exitProcess

/**
 * Crash isolation: a plugin that throws never takes the app down.
 *
 * 1. Every call into plugin code made by the runtime goes through [run], [call] or [wrap].
 * 2. Plugin views are wrapped in [PluginViewContainer], which catches measure, layout, draw and touch failures.
 * 3. Once a plugin is loaded, [install] adds a last line of defence: uncaught exceptions whose stack contains a class
 *    from a plugin's class loader are reported instead of crashing, on background threads (the thread ends) and on
 *    the main thread (the main loop is resumed). Every other exception still crashes the app as before.
 *
 * Reports go to logcat, to the app log through Dart (`log`) and to the `plugin.error` event.
 */
internal object PluginCrashGuard {
  private val loaders = ConcurrentHashMap<String, ClassLoader>()

  @Volatile
  private var installed = false

  fun registerLoader(plugin: String, loader: ClassLoader) {
    loaders[plugin] = loader
  }

  fun unregisterLoader(plugin: String) {
    loaders.remove(plugin)
  }

  inline fun <T> call(plugin: String, where: String, fallback: T, block: () -> T): T = try {
    block()
  } catch (error: Throwable) {
    report(plugin, where, error)
    fallback
  }

  fun run(plugin: String, where: String, block: () -> Unit) {
    try {
      block()
    } catch (error: Throwable) {
      report(plugin, where, error)
    }
  }

  fun wrap(plugin: String, where: String, runnable: Runnable): Runnable = Runnable { run(plugin, where) { runnable.run() } }

  fun report(plugin: String?, where: String, error: Throwable) {
    val name = plugin ?: "unknown"
    Log.e(PluginRuntime.TAG, "Plugin $name failed in $where", error)
    try {
      PluginNativeBridge.log(plugin, "severe", "Plugin $name failed in $where: ${error.message ?: error.javaClass.name}", error)
      PluginEvents.emit(
        "plugin.error",
        JSONObject()
          .put("plugin", name)
          .put("where", where)
          .put("error", error.javaClass.name)
          .put("message", error.message ?: error.toString())
          .put("stack", Log.getStackTraceString(error).take(8000)),
      )
    } catch (secondary: Throwable) {
      Log.e(PluginRuntime.TAG, "Unable to report a plugin error", secondary)
    }
  }

  /** Installs the uncaught-exception and main-loop guards once. Called when the first plugin is loaded. */
  fun install() {
    if (installed) {
      return
    }
    synchronized(this) {
      if (installed) {
        return
      }
      installed = true
    }
    val previous = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { thread, error ->
      val plugin = if (thread !== Looper.getMainLooper().thread) pluginOf(error) else null
      when {
        plugin != null -> report(plugin, "thread ${thread.name}", error)
        previous != null -> previous.uncaughtException(thread, error)
        else -> {
          Log.e(PluginRuntime.TAG, "Uncaught exception on ${thread.name}", error)
          android.os.Process.killProcess(android.os.Process.myPid())
          exitProcess(10)
        }
      }
    }
    PluginRuntime.mainHandler.post { guardMainLoop() }
  }

  /** Runs the main loop nested inside a message so that plugin exceptions can be caught and the loop resumed. */
  private fun guardMainLoop() {
    while (true) {
      try {
        Looper.loop()
        return
      } catch (error: Throwable) {
        val plugin = pluginOf(error) ?: throw error
        report(plugin, "main thread", error)
      }
    }
  }

  private val platformPrefixes = listOf(
    "java.", "javax.", "jdk.", "sun.", "android.", "androidx.", "com.android.", "dalvik.", "libcore.", "kotlin.",
    "kotlinx.", "io.flutter.", "app.alextran.immich.", "org.json.",
  )

  /** The plugin whose class appears in the stack of [error] or its causes, or null. */
  fun pluginOf(error: Throwable): String? {
    if (loaders.isEmpty()) {
      return null
    }
    val seen = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
    var current: Throwable? = error
    while (current != null && seen.size < 10 && seen.add(current)) {
      for (frame in current.stackTrace) {
        val className = frame.className
        if (platformPrefixes.any { className.startsWith(it) }) {
          continue
        }
        for ((plugin, loader) in loaders) {
          val type = try {
            Class.forName(className, false, loader)
          } catch (_: Throwable) {
            null
          }
          if (type != null && type.classLoader === loader) {
            return plugin
          }
        }
      }
      current = current.cause
    }
    return null
  }
}
