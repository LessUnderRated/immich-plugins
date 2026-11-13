package app.alextran.immich.plugins

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import app.alextran.immich.plugins.PluginJson.str
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Background work for plugins on WorkManager: one-off or periodic calls of a plugin method that run even when the app
 * is closed (the plugin is loaded natively in that case; Dart host functions are then unavailable).
 */
internal object PluginBackgroundWork {
  const val KEY_PLUGIN = "plugin"
  const val KEY_ID = "id"
  const val KEY_METHOD = "method"
  const val KEY_PARAMS = "params"
  const val KEY_PERIODIC = "periodic"
  const val KEY_FOREGROUND_TITLE = "foregroundTitle"
  const val KEY_FOREGROUND_TEXT = "foregroundText"
  private const val TAG_ALL = "immich.plugin.work"
  private const val TAG_ID_PREFIX = "immich.plugin.work.id:"
  private const val MAX_PARAMS = 8_000

  private val runs = ConcurrentHashMap<String, PluginWorker>()

  fun tagFor(plugin: String) = "$TAG_ALL:$plugin"

  fun uniqueName(plugin: String, id: String) = "$TAG_ALL:$plugin:$id"

  /**
   * [spec]: `{ id, method, params?, delayMs?, periodMinutes?, flexMinutes?, replace? (true), expedited?, backoffSeconds?,
   * constraints?: { network: none|connected|unmetered|notRoaming|metered, charging, batteryNotLow, idle, storageNotLow },
   * foreground?: { title, text } }`. Returns `{ id, workId, periodic }`.
   */
  fun schedule(context: Context, plugin: String, spec: JSONObject): JSONObject {
    val id = spec.str("id") ?: throw IllegalArgumentException("work id is required")
    val method = spec.str("method") ?: throw IllegalArgumentException("work method is required")
    val params = spec.optJSONObject("params")?.toString() ?: "{}"
    require(params.length <= MAX_PARAMS) { "work params must be smaller than $MAX_PARAMS characters" }
    val periodMinutes = spec.optLong("periodMinutes", 0)
    val delayMs = spec.optLong("delayMs", 0).coerceAtLeast(0)
    val replace = spec.optBoolean("replace", true)
    val foreground = spec.optJSONObject("foreground")
    val constraintsSpec = spec.optJSONObject("constraints") ?: JSONObject()

    val network = when (constraintsSpec.str("network")) {
      "connected" -> NetworkType.CONNECTED
      "unmetered" -> NetworkType.UNMETERED
      "notRoaming" -> NetworkType.NOT_ROAMING
      "metered" -> NetworkType.METERED
      else -> NetworkType.NOT_REQUIRED
    }
    val constraints = Constraints.Builder()
      .setRequiredNetworkType(network)
      .setRequiresCharging(constraintsSpec.optBoolean("charging", false))
      .setRequiresBatteryNotLow(constraintsSpec.optBoolean("batteryNotLow", false))
      .setRequiresDeviceIdle(constraintsSpec.optBoolean("idle", false))
      .setRequiresStorageNotLow(constraintsSpec.optBoolean("storageNotLow", false))
      .build()

    val data = Data.Builder()
      .putString(KEY_PLUGIN, plugin)
      .putString(KEY_ID, id)
      .putString(KEY_METHOD, method)
      .putString(KEY_PARAMS, params)
      .putBoolean(KEY_PERIODIC, periodMinutes > 0)
      .putString(KEY_FOREGROUND_TITLE, foreground?.str("title"))
      .putString(KEY_FOREGROUND_TEXT, foreground?.str("text"))
      .build()
    val backoff = spec.optLong("backoffSeconds", 30).coerceAtLeast(10)
    val manager = WorkManager.getInstance(context)

    if (periodMinutes > 0) {
      val interval = periodMinutes.coerceAtLeast(15)
      val flex = spec.optLong("flexMinutes", 0)
      val builder = if (flex in 5 until interval) {
        PeriodicWorkRequest.Builder(PluginWorker::class.java, interval, TimeUnit.MINUTES, flex, TimeUnit.MINUTES)
      } else {
        PeriodicWorkRequest.Builder(PluginWorker::class.java, interval, TimeUnit.MINUTES)
      }
      builder.setConstraints(constraints)
        .setInputData(data)
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, backoff, TimeUnit.SECONDS)
        .addTag(TAG_ALL)
        .addTag(tagFor(plugin))
        .addTag(TAG_ID_PREFIX + id)
      if (delayMs > 0) {
        builder.setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
      }
      val request = builder.build()
      manager.enqueueUniquePeriodicWork(
        uniqueName(plugin, id),
        if (replace) ExistingPeriodicWorkPolicy.UPDATE else ExistingPeriodicWorkPolicy.KEEP,
        request,
      )
      return JSONObject().put("id", id).put("workId", request.id.toString()).put("periodic", true)
    }

    val builder = OneTimeWorkRequest.Builder(PluginWorker::class.java)
      .setConstraints(constraints)
      .setInputData(data)
      .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, backoff, TimeUnit.SECONDS)
      .addTag(TAG_ALL)
      .addTag(tagFor(plugin))
      .addTag(TAG_ID_PREFIX + id)
    if (delayMs > 0) {
      builder.setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
    } else if (spec.optBoolean("expedited", false)) {
      require(!constraintsSpec.optBoolean("charging", false) && !constraintsSpec.optBoolean("idle", false) &&
        !constraintsSpec.optBoolean("batteryNotLow", false)) {
        "expedited work supports only the network and storageNotLow constraints"
      }
      builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
    }
    val request = builder.build()
    manager.enqueueUniqueWork(uniqueName(plugin, id), if (replace) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP, request)
    return JSONObject().put("id", id).put("workId", request.id.toString()).put("periodic", false)
  }

  fun cancel(context: Context, plugin: String, id: String) {
    WorkManager.getInstance(context).cancelUniqueWork(uniqueName(plugin, id))
  }

  fun cancelAll(context: Context, plugin: String) {
    WorkManager.getInstance(context).cancelAllWorkByTag(tagFor(plugin))
  }

  /** Blocking; call off the main thread. */
  fun list(context: Context, plugin: String): JSONArray {
    val infos = WorkManager.getInstance(context).getWorkInfosByTag(tagFor(plugin)).get(10, TimeUnit.SECONDS)
    val result = JSONArray()
    for (info in infos) {
      val id = info.tags.firstOrNull { it.startsWith(TAG_ID_PREFIX) }?.removePrefix(TAG_ID_PREFIX) ?: continue
      result.put(
        JSONObject()
          .put("id", id)
          .put("workId", info.id.toString())
          .put("state", info.state.name.lowercase())
          .put("runAttempt", info.runAttemptCount)
          .put("running", runs.values.any { it.id == info.id }),
      )
    }
    return result
  }

  fun isStopped(runId: String): Boolean = runs[runId]?.isStopped ?: true

  internal fun track(runId: String, worker: PluginWorker) {
    runs[runId] = worker
  }

  internal fun untrack(runId: String) {
    runs.remove(runId)
  }
}

/** Runs one scheduled plugin call. Input type `WorkV1`; the response `{ "result": "success" | "retry" | "failure" }`. */
class PluginWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
  override fun doWork(): Result {
    val context = applicationContext
    PluginRuntime.ensureInit(context)
    val plugin = inputData.getString(PluginBackgroundWork.KEY_PLUGIN) ?: return Result.failure()
    val workId = inputData.getString(PluginBackgroundWork.KEY_ID) ?: return Result.failure()
    val method = inputData.getString(PluginBackgroundWork.KEY_METHOD) ?: return Result.failure()
    val params = PluginJson.obj(inputData.getString(PluginBackgroundWork.KEY_PARAMS))

    val record = PluginRegistryStore.get(context, plugin)
    if (record == null || !File(record.dexPath).isFile) {
      // Uninstalled: its schedules go too.
      WorkManager.getInstance(context).cancelAllWorkByTag(PluginBackgroundWork.tagFor(plugin))
      return Result.failure()
    }
    if (!record.enabled) {
      return Result.success()
    }
    val instance = PluginRuntime.ensureLoaded(plugin) ?: return Result.failure()

    if (inputData.getString(PluginBackgroundWork.KEY_FOREGROUND_TITLE) != null) {
      try {
        setForegroundAsync(foregroundInfo()).get(10, TimeUnit.SECONDS)
      } catch (error: Throwable) {
        PluginRuntime.log(android.util.Log.WARN, "Plugin work $plugin/$workId could not run in the foreground", error)
      }
    }

    val runId = id.toString()
    PluginBackgroundWork.track(runId, this)
    val event = JSONObject().put("plugin", plugin).put("id", workId).put("runId", runId)
    PluginEvents.emit("work.started", JSONObject(event.toString()))
    val outcome = try {
      val data = JSONObject()
        .put("id", workId)
        .put("runId", runId)
        .put("runAttempt", runAttemptCount)
        .put("periodic", inputData.getBoolean(PluginBackgroundWork.KEY_PERIODIC, false))
        .put("params", params)
      val response = instance.call(method, PluginRuntime.callInput("WorkV1", data), PluginRuntime.host(plugin))
      val json = PluginJson.parse(response) as? JSONObject
      json?.optJSONObject("work")?.optString("result")?.takeIf { it.isNotEmpty() } ?: json?.optString("result")?.takeIf { it.isNotEmpty() }
        ?: "success"
    } catch (error: Throwable) {
      PluginCrashGuard.report(plugin, "work $workId", error)
      "failure"
    } finally {
      PluginBackgroundWork.untrack(runId)
    }
    PluginEvents.emit("work.finished", event.put("result", outcome))
    return when (outcome) {
      "retry" -> Result.retry()
      "failure" -> Result.failure()
      else -> Result.success()
    }
  }

  override fun getForegroundInfo(): ForegroundInfo = foregroundInfo()

  private fun foregroundInfo(): ForegroundInfo {
    val plugin = inputData.getString(PluginBackgroundWork.KEY_PLUGIN) ?: "plugin"
    val workId = inputData.getString(PluginBackgroundWork.KEY_ID) ?: "work"
    val title = inputData.getString(PluginBackgroundWork.KEY_FOREGROUND_TITLE) ?: plugin
    val notification = PluginNotifications.workNotification(
      applicationContext,
      title,
      inputData.getString(PluginBackgroundWork.KEY_FOREGROUND_TEXT),
    )
    val notificationId = "work:$plugin:$workId".hashCode()
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      ForegroundInfo(notificationId, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    } else {
      ForegroundInfo(notificationId, notification)
    }
  }
}
