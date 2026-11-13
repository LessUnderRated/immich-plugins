package app.alextran.immich.plugins

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.widget.TextView
import app.alextran.immich.plugins.api.ImmichViewLifecycle
import app.alextran.immich.plugins.api.ImmichViewPlugin
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import android.os.Build
import android.os.Handler
import android.os.Looper
import app.alextran.immich.plugins.api.HostCallback
import app.alextran.immich.plugins.api.ImmichPlugin
import app.alextran.immich.plugins.api.PluginHost
import dalvik.system.DexClassLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class DexPluginHost(private val context: Context, messenger: BinaryMessenger) :
  MethodChannel.MethodCallHandler, PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  var activity: Activity? = null

  private val channel = MethodChannel(messenger, CHANNEL)
  private val mainHandler = Handler(Looper.getMainLooper())
  private val executor = Executors.newCachedThreadPool { runnable -> Thread(runnable, "dex-plugins") }
  private val plugins = ConcurrentHashMap<String, ImmichPlugin>()
  private val pluginDirs = ConcurrentHashMap<String, File>()

  init {
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "load" -> {
        val key = call.argument<String>("key")!!
        val dexPath = call.argument<String>("dexPath")!!
        val entry = call.argument<String>("entry")!!
        runInBackground(result) {
          plugins[key] = instantiate(key, File(dexPath), entry)
          pluginDirs[key] = File(File(dexPath).parentFile, "files").apply { mkdirs() }
          null
        }
      }

      "unload" -> {
        plugins.remove(call.argument<String>("key")!!)
        result.success(null)
      }

      "call" -> {
        val key = call.argument<String>("key")!!
        val method = call.argument<String>("method")!!
        val input = call.argument<String>("input") ?: "{}"
        runInBackground(result) {
          val plugin = plugins[key] ?: throw IllegalStateException("Plugin $key is not loaded")
          plugin.call(method, input, hostFor(key))
        }
      }

      else -> result.notImplemented()
    }
  }

  private fun instantiate(key: String, source: File, entry: String): ImmichPlugin {
    val directory = File(context.codeCacheDir, "dex-plugins").apply { mkdirs() }
    directory.listFiles { file -> file.name.startsWith("$key-") }?.forEach { stale ->
      stale.setWritable(true)
      stale.delete()
    }
    val target = File(directory, "$key-${source.lastModified()}-${source.length()}.dex")
    source.copyTo(target, overwrite = true)
    target.setReadOnly()

    val optimized = File(directory, "oat").apply { mkdirs() }
    val loader = DexClassLoader(target.path, optimized.path, copyNativeLibraries(key, source.parentFile!!), javaClass.classLoader)
    val instance = loader.loadClass(entry).getDeclaredConstructor().newInstance()
    return instance as? ImmichPlugin
      ?: throw IllegalStateException("$entry does not implement ${ImmichPlugin::class.java.name}")
  }

  private fun copyNativeLibraries(key: String, pluginRoot: File): String? {
    val libraries = File(pluginRoot, "files/lib")
    val abi = Build.SUPPORTED_ABIS.firstOrNull { File(libraries, it).isDirectory } ?: return null
    val target = File(context.codeCacheDir, "dex-plugins/$key-libs")
    if (target.exists()) {
      target.walkBottomUp().forEach { it.setWritable(true) }
      target.deleteRecursively()
    }
    target.mkdirs()
    File(libraries, abi).listFiles { file -> file.name.endsWith(".so") }?.forEach { library ->
      val copy = File(target, library.name)
      library.copyTo(copy, overwrite = true)
      copy.setReadOnly()
    }
    return target.path
  }

  private fun hostFor(key: String) = object : PluginHost {
    override val context: Context = this@DexPluginHost.context
    override val dataDir: File = File(context.filesDir, "dex-plugin-data/$key").apply { mkdirs() }
    override val pluginDir: File = pluginDirs[key] ?: dataDir
    override val pluginName: String = key
    override val activity: Activity? get() = this@DexPluginHost.activity

    override val hostApiVersion: Int = HOST_API_VERSION

    override fun callHost(name: String, argsJson: String): String =
      invokeHost(key, name, hostInput(argsJson))

    override fun callHostAsync(name: String, argsJson: String, callback: HostCallback) {
      invokeHostAsync(key, name, hostInput(argsJson)) { response ->
        executor.execute {
          try {
            callback.onResult(response)
          } catch (error: Throwable) {
            android.util.Log.w("DexPluginHost", "Plugin $key failed handling the result of $name", error)
          }
        }
      }
    }

    override fun emit(event: String, payloadJson: String) {
      mainHandler.post {
        channel.invokeMethod("emit", mapOf("plugin" to key, "event" to event, "payload" to payloadJson.ifBlank { "{}" }))
      }
    }

    override fun runOnUi(block: Runnable) {
      mainHandler.post(block)
    }

    override fun sendEvent(name: String, payloadJson: String) {
      mainHandler.post { channel.invokeMethod("event", mapOf("plugin" to key, "name" to name, "payload" to payloadJson)) }
    }
  }

  private fun hostInput(argsJson: String): String = "{\"authToken\":\"\",\"args\":${argsJson.ifBlank { "[]" }}}"

  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    val params = args as? Map<*, *> ?: emptyMap<String, Any>()
    val key = params["plugin"] as? String ?: ""
    val viewType = params["view"] as? String ?: ""
    val rawJson = params["params"] as? String ?: "{}"
    // The plugin sees the platform view id (for frame capture and lifecycle) and how the view is composited.
    val json = try {
      JSONObject(rawJson)
        .put("viewId", viewId)
        .put("composition", params["composition"] as? String ?: "texture")
        .toString()
    } catch (error: Throwable) {
      rawJson
    }
    val plugin = plugins[key]
    val viewContext = activity ?: context
    val view = try {
      (plugin as? ImmichViewPlugin)?.createView(viewContext, viewType, json, hostFor(key))
        ?: message(viewContext, "Plugin $key has no view \"$viewType\"")
    } catch (error: Throwable) {
      message(viewContext, "Plugin view failed: ${error.message ?: error}")
    }
    return object : PlatformView {
      override fun getView(): View = view

      override fun dispose() {
        (plugin as? ImmichViewLifecycle)?.onViewDisposed(viewType, view)
      }
    }
  }

  private fun message(context: Context, text: String): View = TextView(context).apply {
    this.text = text
    setTextColor(Color.WHITE)
    gravity = Gravity.CENTER
  }

  private fun runInBackground(result: MethodChannel.Result, block: () -> String?) {
    executor.execute {
      try {
        val value = block()
        mainHandler.post { result.success(value) }
      } catch (error: Throwable) {
        val cause = error.cause ?: error
        mainHandler.post { result.error("plugin_error", cause.message ?: cause.toString(), cause.stackTraceToString()) }
      }
    }
  }

  /** Sends a host call to Dart from any thread; [done] runs on the UI thread with the result envelope. */
  private fun invokeHostAsync(key: String, name: String, input: String, done: (String) -> Unit) {
    mainHandler.post {
      channel.invokeMethod(
        "host",
        mapOf("plugin" to key, "name" to name, "input" to input),
        object : MethodChannel.Result {
          override fun success(value: Any?) {
            done(value as? String ?: errorJson(500, "Host function $name returned nothing"))
          }

          override fun error(code: String, message: String?, details: Any?) {
            done(errorJson(500, message ?: code))
          }

          override fun notImplemented() {
            done(errorJson(501, "Host function $name is not implemented"))
          }
        },
      )
    }
  }

  private fun invokeHost(key: String, name: String, input: String): String {
    if (Looper.myLooper() == Looper.getMainLooper()) {
      // Blocking here would deadlock: the answer is delivered on this thread.
      return errorJson(409, "callHost($name) cannot block the UI thread; use callHostAsync")
    }
    val latch = CountDownLatch(1)
    val response = AtomicReference<String?>(null)
    invokeHostAsync(key, name, input) { value ->
      response.set(value)
      latch.countDown()
    }

    if (!latch.await(HOST_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
      return errorJson(504, "Host function $name timed out")
    }
    return response.get() ?: errorJson(500, "Host function $name returned nothing")
  }

  companion object {
    const val CHANNEL = "immich/dex_plugins"
    const val VIEW_TYPE = "immich/plugin_view"
    const val HOST_API_VERSION = 2
    private const val HOST_TIMEOUT_SECONDS = 300L

    private fun errorJson(status: Int, message: String): String =
      JSONObject().put("success", false).put("status", status).put("message", message).toString()
  }
}
