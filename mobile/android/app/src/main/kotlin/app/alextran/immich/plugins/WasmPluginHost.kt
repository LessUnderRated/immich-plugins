package app.alextran.immich.plugins

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.dylibso.chicory.log.Logger
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.extism.sdk.chicory.ExtismHostFunction
import org.extism.sdk.chicory.ExtismValType
import org.extism.sdk.chicory.Manifest
import org.extism.sdk.chicory.ManifestWasm
import org.extism.sdk.chicory.Plugin
import org.extism.sdk.chicory.http.HttpClientAdapter
import org.extism.sdk.chicory.http.HttpConfig
import org.extism.sdk.chicory.http.HttpJsonCodec
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class WasmPluginHost(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
  private val channel = MethodChannel(messenger, CHANNEL)
  private val mainHandler = Handler(Looper.getMainLooper())
  private val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "wasm-plugins") }
  private val plugins = ConcurrentHashMap<String, Plugin>()

  init {
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "load" -> {
        val key = call.argument<String>("key")!!
        val path = call.argument<String>("wasmPath")!!
        val functions = call.argument<List<String>>("hostFunctions") ?: emptyList()
        val enabled = call.argument<Boolean>("enableHostFunctions") ?: false
        runInBackground(result) {
          plugins[key] = build(key, File(path).readBytes(), functions, enabled)
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
        val input = call.argument<String>("input") ?: ""
        runInBackground(result) {
          val plugin = plugins[key] ?: throw IllegalStateException("Plugin $key is not loaded")
          plugin.call(method, input.toByteArray())?.toString(Charsets.UTF_8)
        }
      }

      else -> result.notImplemented()
    }
  }

  private fun runInBackground(result: MethodChannel.Result, block: () -> String?) {
    executor.execute {
      try {
        val value = block()
        mainHandler.post { result.success(value) }
      } catch (error: Throwable) {
        mainHandler.post { result.error("plugin_error", error.message ?: error.toString(), error.cause?.toString()) }
      }
    }
  }

  private fun build(key: String, wasm: ByteArray, functionNames: List<String>, enabled: Boolean): Plugin {
    val functions = functionNames.map { name ->
      ExtismHostFunction.of(name, listOf(ExtismValType.I64), listOf(ExtismValType.I64)) { plugin, params, returns ->
        val input = plugin.memory().readString(params.getRaw(0))
        val response = if (enabled) invokeHost(key, name, input) else errorJson(403, "Host functions are not enabled for this method")
        returns.setRaw(0, plugin.memory().writeString(response))
      }
    }

    val options = Manifest.Options().withHttpConfig(disabledHttp)
    val manifest = Manifest.ofWasms(ManifestWasm.fromBytes(wasm).build()).withOptions(options).build()
    return Plugin.ofManifest(manifest)
      .withHostFunctions(*functions.toTypedArray())
      .withLogger(AndroidLogger)
      .build()
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
    private object AndroidLogger : Logger {
      override fun log(level: Logger.Level, msg: String?, throwable: Throwable?) {
        when (level) {
          Logger.Level.ERROR -> Log.e(TAG, msg, throwable)
          Logger.Level.WARNING -> Log.w(TAG, msg, throwable)
          else -> Log.d(TAG, msg, throwable)
        }
      }

      override fun isLoggable(level: Logger.Level): Boolean =
        level == Logger.Level.ERROR || level == Logger.Level.WARNING
    }

    private const val TAG = "WasmPlugins"
    const val CHANNEL = "immich/wasm_plugins"
    private const val HOST_TIMEOUT_SECONDS = 120L

    private fun errorJson(status: Int, message: String): String =
      JSONObject().put("success", false).put("status", status).put("message", message).toString()

    private val disabledHttp: HttpConfig = HttpConfig.builder()
      .withJsonCodec {
        object : HttpJsonCodec {
          override fun decodeMetadata(bytes: ByteArray): HttpJsonCodec.RequestMetadata =
            throw UnsupportedOperationException("Use the httpRequest host function")

          override fun encodeHeaders(headers: Map<String, List<String>>): ByteArray = ByteArray(0)
        }
      }
      .withClientAdapter {
        object : HttpClientAdapter {
          override fun request(method: String, uri: URI, headers: Map<String, String>, body: ByteArray): ByteArray =
            throw UnsupportedOperationException("Use the httpRequest host function")

          override fun statusCode(): Int = 0

          override fun headers(): Map<String, List<String>> = emptyMap()
        }
      }
      .build()
  }
}
