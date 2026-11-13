package app.alextran.immich.plugins

import android.app.Activity
import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.util.Log
import android.view.View
import app.alextran.immich.plugins.api.ActivityResultListener
import app.alextran.immich.plugins.api.IntentInterceptor
import app.alextran.immich.plugins.api.LifecycleListener
import app.alextran.immich.plugins.api.NativeActivityResults
import app.alextran.immich.plugins.api.NativeAsyncHostFunction
import app.alextran.immich.plugins.api.NativeEventListener
import app.alextran.immich.plugins.api.NativeEvents
import app.alextran.immich.plugins.api.NativeHost
import app.alextran.immich.plugins.api.NativeHostFunction
import app.alextran.immich.plugins.api.NativeHostFunctions
import app.alextran.immich.plugins.api.NativeIntents
import app.alextran.immich.plugins.api.NativeLifecycle
import app.alextran.immich.plugins.api.NativeMedia
import app.alextran.immich.plugins.api.NativeNotifications
import app.alextran.immich.plugins.api.NativePermissions
import app.alextran.immich.plugins.api.NativePlugins
import app.alextran.immich.plugins.api.NativeVideo
import app.alextran.immich.plugins.api.NativeViews
import app.alextran.immich.plugins.api.NativeWork
import app.alextran.immich.plugins.api.PermissionsCallback
import app.alextran.immich.plugins.api.PluginTheme
import app.alextran.immich.plugins.api.Registration
import app.alextran.immich.plugins.api.ResultCallback
import app.alextran.immich.plugins.api.ThemeListener
import app.alextran.immich.plugins.api.VideoSession
import app.alextran.immich.plugins.api.VideoSessionsListener
import java.io.File

/** The [NativeHost] of one plugin. Every registration is tracked in the plugin's scope. */
class NativeHostImpl internal constructor(override val pluginName: String) : NativeHost {
  private fun guard(where: String, block: () -> Unit) = PluginCrashGuard.run(pluginName, where, block)

  override val apiVersion: Int get() = PluginRuntime.API_VERSION

  override val features: Set<String> get() = PluginRuntime.FEATURES

  override fun hasFeature(feature: String): Boolean = feature in PluginRuntime.FEATURES

  override val context: Context get() = PluginRuntime.context

  override val activity: Activity? get() = PluginLifecycle.currentActivity

  override val binaryMessenger: Any? get() = PluginRuntime.engine?.dartExecutor?.binaryMessenger

  override val flutterEngine: Any? get() = PluginRuntime.engine

  override fun log(level: String, message: String, error: Throwable?) {
    val priority = when (level.lowercase()) {
      "fine", "debug" -> Log.DEBUG
      "warning", "warn" -> Log.WARN
      "severe", "error" -> Log.ERROR
      else -> Log.INFO
    }
    PluginRuntime.log(priority, "[$pluginName] $message", error)
    PluginNativeBridge.log(pluginName, level.lowercase(), message, error)
  }

  override fun setLoadOnStartup(enabled: Boolean) = PluginRuntime.setLoadOnStartup(pluginName, enabled)

  override fun runGuarded(where: String, block: Runnable) = guard(where) { block.run() }

  // ---- events ---------------------------------------------------------------------------------------------------

  override val events: NativeEvents = object : NativeEvents {
    override fun emit(event: String, payloadJson: String) = PluginEvents.emitFromPlugin(pluginName, event, payloadJson)

    override fun addListener(pattern: String, listener: NativeEventListener): Registration =
      PluginEvents.addListener(pluginName, pattern, listener)
  }

  // ---- lifecycle and intents ------------------------------------------------------------------------------------

  override val lifecycle: NativeLifecycle = object : NativeLifecycle {
    override val currentActivity: Activity? get() = PluginLifecycle.currentActivity

    override val isForeground: Boolean get() = PluginLifecycle.isForeground

    override fun addListener(listener: LifecycleListener): Registration = PluginLifecycle.addListener(pluginName, listener)
  }

  override val intents: NativeIntents = object : NativeIntents {
    override val currentIntent: Intent? get() = PluginIntents.currentIntent

    override fun addInterceptor(interceptor: IntentInterceptor): Registration = addInterceptor(interceptor, 0)

    override fun addInterceptor(interceptor: IntentInterceptor, priority: Int): Registration =
      PluginIntents.addInterceptor(pluginName, interceptor, priority)

    override fun toJson(intent: Intent): String = PluginIntents.toJson(intent).toString()
  }

  // ---- permissions and results ----------------------------------------------------------------------------------

  override val permissions: NativePermissions = object : NativePermissions {
    override fun isGranted(permission: String): Boolean = PluginActivityResults.isGranted(permission)

    override fun shouldShowRationale(permission: String): Boolean = PluginActivityResults.shouldShowRationale(permission)

    override fun request(permissions: Array<String>, callback: PermissionsCallback) =
      PluginActivityResults.requestPermissions(pluginName, permissions.toList()) { results ->
        guard("permissions callback") { callback.onResult(results) }
      }

    override fun openAppSettings() = PluginActivityResults.openAppSettings()
  }

  override val activityResults: NativeActivityResults = object : NativeActivityResults {
    override fun startActivityForResult(intent: Intent, callback: ActivityResultListener) =
      PluginActivityResults.startActivityForResult(intent) { code, data ->
        guard("activity result") { callback.onActivityResult(code, data) }
      }

    override fun startIntentSenderForResult(sender: IntentSender, callback: ActivityResultListener) =
      PluginActivityResults.startIntentSenderForResult(sender) { code, data ->
        guard("activity result") { callback.onActivityResult(code, data) }
      }
  }

  // ---- notifications and work -----------------------------------------------------------------------------------

  override val notifications: NativeNotifications = object : NativeNotifications {
    override val enabled: Boolean get() = PluginNotifications.enabled(context)

    override val smallIcon: Int get() = PluginNotifications.smallIcon

    override fun createChannel(id: String, name: String, importance: Int, description: String?): String =
      PluginNotifications.createChannel(context, pluginName, id, name, importance, description)

    override fun deleteChannel(id: String) = PluginNotifications.deleteChannel(context, pluginName, id)

    override fun channelId(id: String): String = PluginNotifications.channelId(pluginName, id)

    override fun post(specJson: String): String =
      PluginNotifications.post(context, pluginName, PluginJson.obj(specJson)).toString()

    override fun post(id: String, notification: Notification) = PluginNotifications.postRaw(context, pluginName, id, notification)

    override fun cancel(id: String) = PluginNotifications.cancel(context, pluginName, id)

    override fun cancelAll() = PluginNotifications.cancelAll(context, pluginName)

    override fun active(): List<String> = PluginNotifications.active(context, pluginName)

    override fun actionIntent(id: String, actionId: String, method: String?, paramsJson: String?, replyLabel: String?): PendingIntent =
      PluginNotifications.actionIntent(context, pluginName, id, actionId, method, paramsJson, replyLabel)

    override fun contentIntent(id: String, method: String?, paramsJson: String?, openApp: Boolean): PendingIntent =
      PluginNotifications.contentIntent(context, pluginName, id, method, paramsJson, openApp)
  }

  override val work: NativeWork = object : NativeWork {
    override fun schedule(specJson: String): String =
      PluginBackgroundWork.schedule(context, pluginName, PluginJson.obj(specJson)).toString()

    override fun cancel(id: String) = PluginBackgroundWork.cancel(context, pluginName, id)

    override fun cancelAll() = PluginBackgroundWork.cancelAll(context, pluginName)

    override fun list(): String = PluginBackgroundWork.list(context, pluginName).toString()

    override fun isStopped(runId: String): Boolean = PluginBackgroundWork.isStopped(runId)
  }

  // ---- media ----------------------------------------------------------------------------------------------------

  override val media: NativeMedia = object : NativeMedia {
    private fun save(source: File, optionsJson: String, video: Boolean, callback: ResultCallback) {
      PluginRuntime.executor.execute {
        val envelope = try {
          PluginJson.ok(PluginMedia.save(context, source, PluginJson.obj(optionsJson), video).toString())
        } catch (error: SecurityException) {
          PluginJson.error(403, error.message ?: error.toString())
        } catch (error: Throwable) {
          PluginJson.error(500, error.message ?: error.toString())
        }
        guard("media callback") { callback.onResult(envelope) }
      }
    }

    override fun saveImage(source: File, optionsJson: String, callback: ResultCallback) = save(source, optionsJson, false, callback)

    override fun saveVideo(source: File, optionsJson: String, callback: ResultCallback) = save(source, optionsJson, true, callback)

    override fun replace(assetId: String, video: Boolean, source: File, optionsJson: String, callback: ResultCallback) =
      PluginMedia.replace(context, assetId, video, source, PluginJson.obj(optionsJson)) { result, error ->
        val envelope = when {
          result != null -> PluginJson.ok(result.toString())
          error is SecurityException -> PluginJson.error(403, error.message ?: error.toString())
          else -> PluginJson.error(500, error?.message ?: "Replacing the item failed")
        }
        guard("media callback") { callback.onResult(envelope) }
      }
  }

  // ---- video and views ------------------------------------------------------------------------------------------

  override val video: NativeVideo = object : NativeVideo {
    override val sessions: List<VideoSession>
      get() = PluginVideoSessions.all().map { ScopedVideoSession(pluginName, it) }

    override fun session(sessionId: String): VideoSession? =
      PluginVideoSessions.get(sessionId)?.let { ScopedVideoSession(pluginName, it) }

    override fun addListener(listener: VideoSessionsListener): Registration = PluginVideoSessions.addListener(pluginName, listener)
  }

  override val views: NativeViews = object : NativeViews {
    override val theme: PluginTheme get() = PluginViews.theme

    override fun addThemeListener(listener: ThemeListener): Registration = PluginViews.addThemeListener(pluginName, listener)

    override fun setContentHeight(view: View, heightPx: Int) = PluginViews.setContentHeight(view, heightPx)

    override fun autoContentHeight(view: View): Registration = PluginViews.autoContentHeight(pluginName, view)

    override fun viewId(view: View): Int = PluginViews.viewId(view)
  }

  // ---- other plugins and host functions -------------------------------------------------------------------------

  override val plugins: NativePlugins = object : NativePlugins {
    override val loaded: List<String> get() = PluginRuntime.loadedPlugins()

    override fun isLoaded(plugin: String): Boolean = PluginRuntime.plugin(plugin) != null

    override fun call(plugin: String, method: String, type: String, dataJson: String): String? =
      PluginRuntime.callPlugin(plugin, method, PluginRuntime.callInput(type, PluginJson.parse(dataJson), mapOf("caller" to pluginName)))

    override fun callAsync(plugin: String, method: String, type: String, dataJson: String, callback: ResultCallback) {
      PluginRuntime.executor.execute {
        val envelope = try {
          PluginJson.ok(call(plugin, method, type, dataJson))
        } catch (error: Throwable) {
          PluginJson.error(500, error.message ?: error.toString())
        }
        guard("plugin call callback") { callback.onResult(envelope) }
      }
    }

    override fun registerService(name: String, service: Any): Registration = PluginServices.register(pluginName, name, service)

    override fun service(name: String): Any? = PluginServices.get(name)

    override val services: List<String> get() = PluginServices.names()
  }

  override val hostFunctions: NativeHostFunctions = object : NativeHostFunctions {
    override fun register(name: String, function: NativeHostFunction): Registration =
      PluginHostFunctions.register(pluginName, name, function, null)

    override fun registerAsync(name: String, function: NativeAsyncHostFunction): Registration =
      PluginHostFunctions.register(pluginName, name, null, function)

    override fun call(name: String, argsJson: String): String = PluginHostFunctions.call(pluginName, name, argsJson)

    override fun callAsync(name: String, argsJson: String, callback: ResultCallback) =
      PluginHostFunctions.callAsync(pluginName, name, argsJson) { envelope ->
        guard("host function callback") { callback.onResult(envelope) }
      }

    override fun has(name: String): Boolean = PluginHostFunctions.has(name)

    override val names: List<String> get() = PluginHostFunctions.names()
  }
}
