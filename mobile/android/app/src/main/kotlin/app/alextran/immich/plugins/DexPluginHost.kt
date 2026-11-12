package app.alextran.immich.plugins

import android.content.Context
import android.os.Handler
import android.os.Looper
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

class DexPluginHost(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
  private val channel = MethodChannel(messenger, CHANNEL)
  private val mainHandler = Handler(Looper.getMainLooper())
  private val executor = Executors.newCachedThreadPool { runnable -> Thread(runnable, "dex-plugins") }
  private val plugins = ConcurrentHashMap<String, ImmichPlugin>()

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
    val loader = DexClassLoader(target.path, optimized.path, null, javaClass.classLoader)
    val instance = loader.loadClass(entry).getDeclaredConstructor().newInstance()
    return instance as? ImmichPlugin
      ?: throw IllegalStateException("$entry does not implement ${ImmichPlugin::class.java.name}")
  }

  private fun hostFor(key: String) = object : PluginHost {
    override val context: Context = this@DexPluginHost.context
    override val dataDir: File = File(context.filesDir, "dex-plugin-data/$key").apply { mkdirs() }
    override val pluginName: String = key

    override fun callHost(name: String, argsJson: String): String =
      invokeHost(key, name, "{\"authToken\":\"\",\"args\":$argsJson}")
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

  private fun invokeHost(key: String, name: String, input: String): String {
    val latch = CountDownLatch(1)
    var response: String? = null
    mainHandler.post {
      channel.invokeMethod(
        "host",
        mapOf("plugin" to key, "name" to name, "input" to input),
        object : MethodChannel.Result {
          override fun success(value: Any?) {
            response = value as? String
            latch.countDown()
          }

          override fun error(code: String, message: String?, details: Any?) {
            response = errorJson(500, message ?: code)
            latch.countDown()
          }

          override fun notImplemented() {
            response = errorJson(501, "Host function $name is not implemented")
            latch.countDown()
          }
        },
      )
    }

    if (!latch.await(HOST_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
      return errorJson(504, "Host function $name timed out")
    }
    return response ?: errorJson(500, "Host function $name returned nothing")
  }

  companion object {
    const val CHANNEL = "immich/dex_plugins"
    private const val HOST_TIMEOUT_SECONDS = 300L

    private fun errorJson(status: Int, message: String): String =
      JSONObject().put("success", false).put("status", status).put("message", message).toString()
  }
}
