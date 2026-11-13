package app.alextran.immich.plugins

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.Log
import app.alextran.immich.R
import app.alextran.immich.plugins.PluginJson.longOrNull
import app.alextran.immich.plugins.PluginJson.str
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Plugin notifications: per-plugin channels and ids, JSON specs, action buttons and taps that call back into the
 * plugin (also when the app is closed), plus the app-native progress notification of the generic Tasks capability.
 */
internal object PluginNotifications {
  const val ACTION_EVENT = "app.alextran.immich.plugins.NOTIFICATION_EVENT"
  const val ACTION_TAP = "app.alextran.immich.plugins.NOTIFICATION_TAP"
  const val REPLY_KEY = "immich.plugin.reply"

  private const val EXTRA_KIND = "immich.plugin.kind"
  private const val EXTRA_PLUGIN = "immich.plugin.name"
  private const val EXTRA_ID = "immich.plugin.id"
  private const val EXTRA_ACTION = "immich.plugin.action"
  private const val EXTRA_METHOD = "immich.plugin.method"
  private const val EXTRA_PARAMS = "immich.plugin.params"
  private const val EXTRA_DISMISS = "immich.plugin.dismiss"

  private const val KIND_ACTION = "action"
  private const val KIND_TAP = "tap"
  private const val KIND_DISMISS = "dismiss"
  private const val KIND_TASK_CANCEL = "taskCancel"

  private const val TASK_CHANNEL = "immich.plugin.tasks"
  private const val WORK_CHANNEL = "immich.plugin.work"
  private const val TASK_TAG = "immich.task"
  private const val CALLBACK_TIMEOUT_MS = 9_000L

  val smallIcon: Int get() = R.drawable.notification_icon

  fun tag(plugin: String) = "immich.plugin:$plugin"

  fun channelId(plugin: String, id: String) = "immich.plugin.$plugin.$id"

  private fun manager(context: Context): NotificationManager = context.getSystemService(NotificationManager::class.java)

  fun enabled(context: Context): Boolean {
    val permission = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
      context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    return permission && manager(context).areNotificationsEnabled()
  }

  fun importance(name: String?): Int = when (name?.lowercase()) {
    "none" -> NotificationManager.IMPORTANCE_NONE
    "min" -> NotificationManager.IMPORTANCE_MIN
    "low" -> NotificationManager.IMPORTANCE_LOW
    "high" -> NotificationManager.IMPORTANCE_HIGH
    "max" -> NotificationManager.IMPORTANCE_MAX
    else -> NotificationManager.IMPORTANCE_DEFAULT
  }

  // ---- channels -------------------------------------------------------------------------------------------------

  fun createChannel(context: Context, plugin: String, id: String, name: String, importance: Int, description: String?): String {
    val channelId = channelId(plugin, id)
    val channel = NotificationChannel(channelId, name, importance)
    if (description != null) {
      channel.description = description
    }
    manager(context).createNotificationChannel(channel)
    return channelId
  }

  fun deleteChannel(context: Context, plugin: String, id: String) {
    manager(context).deleteNotificationChannel(channelId(plugin, id))
  }

  private fun defaultChannel(context: Context, plugin: String): String {
    val id = channelId(plugin, "default")
    if (manager(context).getNotificationChannel(id) == null) {
      createChannel(context, plugin, "default", plugin, NotificationManager.IMPORTANCE_DEFAULT, null)
    }
    return id
  }

  private fun ensureAppChannel(context: Context, id: String, name: String) {
    if (manager(context).getNotificationChannel(id) == null) {
      manager(context).createNotificationChannel(NotificationChannel(id, name, NotificationManager.IMPORTANCE_LOW))
    }
  }

  // ---- posting --------------------------------------------------------------------------------------------------

  /** Posts the notification described by [spec]; returns `{ posted, id, reason? }`. */
  fun post(context: Context, plugin: String, spec: JSONObject): JSONObject {
    val id = spec.str("id") ?: throw IllegalArgumentException("Notification id is required")
    val result = JSONObject().put("id", id)
    if (!enabled(context)) {
      return result.put("posted", false).put("reason", "disabled")
    }
    manager(context).notify(tag(plugin), id.hashCode(), build(context, plugin, id, spec))
    return result.put("posted", true)
  }

  fun postRaw(context: Context, plugin: String, id: String, notification: Notification) {
    notification.extras.putString(EXTRA_ID, id)
    notification.extras.putString(EXTRA_PLUGIN, plugin)
    manager(context).notify(tag(plugin), id.hashCode(), notification)
  }

  fun cancel(context: Context, plugin: String, id: String) {
    manager(context).cancel(tag(plugin), id.hashCode())
  }

  fun cancelAll(context: Context, plugin: String) {
    val tag = tag(plugin)
    for (notification in manager(context).activeNotifications) {
      if (notification.tag == tag) {
        manager(context).cancel(notification.tag, notification.id)
      }
    }
  }

  fun active(context: Context, plugin: String): List<String> {
    val tag = tag(plugin)
    return manager(context).activeNotifications
      .filter { it.tag == tag }
      .mapNotNull { it.notification.extras.getString(EXTRA_ID) }
  }

  private fun build(context: Context, plugin: String, id: String, spec: JSONObject): Notification {
    val requested = spec.str("channel")
    val channel = requested?.let { channelId(plugin, it) }?.takeIf { manager(context).getNotificationChannel(it) != null }
      ?: defaultChannel(context, plugin)
    val builder = Notification.Builder(context, channel)
      .setSmallIcon(R.drawable.notification_icon)
      .setOnlyAlertOnce(spec.optBoolean("onlyAlertOnce", true))
      .setAutoCancel(spec.optBoolean("autoCancel", true))
      .setOngoing(spec.optBoolean("ongoing", false))
    spec.str("smallIcon")?.let { path -> decodeBitmap(path, 128)?.let { builder.setSmallIcon(Icon.createWithBitmap(it)) } }
    spec.str("title")?.let { builder.setContentTitle(it) }
    spec.str("text")?.let { builder.setContentText(it) }
    spec.str("subText")?.let { builder.setSubText(it) }
    spec.str("bigText")?.let { builder.setStyle(Notification.BigTextStyle().bigText(it)) }
    spec.str("image")?.let { path -> decodeBitmap(path, 1024)?.let { builder.setStyle(Notification.BigPictureStyle().bigPicture(it)) } }
    spec.str("largeIcon")?.let { path -> decodeBitmap(path, 256)?.let { builder.setLargeIcon(it) } }
    spec.str("color")?.let { color ->
      try {
        builder.setColor(Color.parseColor(color))
      } catch (_: IllegalArgumentException) {
        Log.w(PluginRuntime.TAG, "Invalid notification color $color")
      }
    }
    spec.str("category")?.let { builder.setCategory(it) }
    spec.str("group")?.let { builder.setGroup(it) }
    if (spec.optBoolean("groupSummary", false)) {
      builder.setGroupSummary(true)
    }
    spec.longOrNull("when")?.let { builder.setWhen(it).setShowWhen(true) }
    spec.longOrNull("timeoutMs")?.let { builder.setTimeoutAfter(it) }
    if (spec.optBoolean("silent", false) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      builder.setSilent(true)
    }
    applyProgress(builder, spec.opt("progress"))

    val tap = spec.optJSONObject("tap")
    builder.setContentIntent(
      contentIntent(context, plugin, id, tap?.str("method"), tap?.optJSONObject("params")?.toString(), tap?.optBoolean("open", true) ?: true),
    )
    val dismiss = spec.optJSONObject("onDismiss")
    builder.setDeleteIntent(
      broadcast(context, KIND_DISMISS, plugin, id, null, dismiss?.str("method"), dismiss?.optJSONObject("params")?.toString(), false, false),
    )

    val actions = spec.optJSONArray("actions") ?: JSONArray()
    for (index in 0 until minOf(actions.length(), 3)) {
      val action = actions.optJSONObject(index) ?: continue
      val actionId = action.str("id") ?: "action$index"
      val title = action.str("title") ?: actionId
      val replyLabel = action.optJSONObject("reply")?.let { it.str("label") ?: title }
      val method = action.str("method")
      val params = action.optJSONObject("params")?.toString()
      val dismissOnTap = action.optBoolean("dismiss", false)
      val pendingIntent = if (action.optBoolean("open", false)) {
        activityIntent(context, KIND_ACTION, plugin, id, actionId, method, params, dismissOnTap)
      } else {
        broadcast(context, KIND_ACTION, plugin, id, actionId, method, params, dismissOnTap, replyLabel != null)
      }
      val button = Notification.Action.Builder(Icon.createWithResource(context, R.drawable.notification_icon), title, pendingIntent)
      if (replyLabel != null) {
        button.addRemoteInput(RemoteInput.Builder(REPLY_KEY).setLabel(replyLabel).build())
      }
      builder.addAction(button.build())
    }
    builder.addExtras(Bundle().apply {
      putString(EXTRA_ID, id)
      putString(EXTRA_PLUGIN, plugin)
    })
    return builder.build()
  }

  private fun applyProgress(builder: Notification.Builder, progress: Any?) {
    when (progress) {
      true -> builder.setProgress(0, 0, true)
      is Number -> builder.setProgress(1000, (progress.toDouble().coerceIn(0.0, 1.0) * 1000).toInt(), false)
      is JSONObject -> builder.setProgress(
        progress.optInt("max", 100),
        progress.optInt("value", 0),
        progress.optBoolean("indeterminate", false),
      )
    }
  }

  private fun decodeBitmap(path: String, maxSize: Int): Bitmap? = try {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(path, bounds)
    var sample = 1
    while (bounds.outWidth / (sample * 2) >= maxSize || bounds.outHeight / (sample * 2) >= maxSize) {
      sample *= 2
    }
    BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
  } catch (error: Throwable) {
    Log.w(PluginRuntime.TAG, "Unable to read notification image $path", error)
    null
  }

  // ---- pending intents ------------------------------------------------------------------------------------------

  private fun requestCode(vararg parts: String?): Int = parts.joinToString("|").hashCode()

  private fun fill(intent: Intent, kind: String, plugin: String?, id: String?, actionId: String?, method: String?, params: String?, dismiss: Boolean): Intent =
    intent
      .putExtra(EXTRA_KIND, kind)
      .putExtra(EXTRA_PLUGIN, plugin)
      .putExtra(EXTRA_ID, id)
      .putExtra(EXTRA_ACTION, actionId)
      .putExtra(EXTRA_METHOD, method)
      .putExtra(EXTRA_PARAMS, params)
      .putExtra(EXTRA_DISMISS, dismiss)

  private fun broadcast(
    context: Context,
    kind: String,
    plugin: String?,
    id: String?,
    actionId: String?,
    method: String?,
    params: String?,
    dismiss: Boolean,
    mutable: Boolean,
  ): PendingIntent {
    val intent = fill(Intent(context, PluginNotificationReceiver::class.java).setAction(ACTION_EVENT), kind, plugin, id, actionId, method, params, dismiss)
    val mutability = when {
      !mutable -> PendingIntent.FLAG_IMMUTABLE
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> PendingIntent.FLAG_MUTABLE
      else -> 0
    }
    return PendingIntent.getBroadcast(context, requestCode(kind, plugin, id, actionId), intent, PendingIntent.FLAG_UPDATE_CURRENT or mutability)
  }

  private fun launchIntent(context: Context): Intent =
    context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { Intent(it) }
      ?: Intent(Intent.ACTION_MAIN).setPackage(context.packageName)

  private fun activityIntent(
    context: Context,
    kind: String,
    plugin: String?,
    id: String?,
    actionId: String?,
    method: String?,
    params: String?,
    dismiss: Boolean,
  ): PendingIntent {
    val intent = launchIntent(context).setAction(ACTION_TAP).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    intent.removeCategory(Intent.CATEGORY_LAUNCHER)
    fill(intent, kind, plugin, id, actionId, method, params, dismiss)
    return PendingIntent.getActivity(
      context,
      requestCode("activity", kind, plugin, id, actionId),
      intent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
  }

  fun actionIntent(context: Context, plugin: String, id: String, actionId: String, method: String?, params: String?, replyLabel: String?): PendingIntent =
    broadcast(context, KIND_ACTION, plugin, id, actionId, method, params, false, replyLabel != null)

  fun contentIntent(context: Context, plugin: String, id: String, method: String?, params: String?, openApp: Boolean): PendingIntent =
    if (openApp) {
      activityIntent(context, KIND_TAP, plugin, id, null, method, params, false)
    } else {
      broadcast(context, KIND_TAP, plugin, id, null, method, params, false, false)
    }

  // ---- callbacks ------------------------------------------------------------------------------------------------

  /** Called by [PluginIntents] for every intent of the main activity; true when it was a plugin notification tap. */
  fun handleTapIntent(intent: Intent): Boolean {
    if (intent.action != ACTION_TAP) {
      return false
    }
    dispatch(PluginRuntime.context, intent, null)
    return true
  }

  /** Handles a tap, action, dismissal or task cancel; [done] runs once when finished (or after a timeout). */
  fun dispatch(context: Context, intent: Intent, done: (() -> Unit)?) {
    val finished = AtomicBoolean(false)
    val finish = {
      if (finished.compareAndSet(false, true)) {
        done?.invoke()
      }
    }
    val kind = intent.getStringExtra(EXTRA_KIND)
    val plugin = intent.getStringExtra(EXTRA_PLUGIN)
    val id = intent.getStringExtra(EXTRA_ID)
    if (kind == KIND_TASK_CANCEL) {
      PluginEvents.emit("task.cancelled", JSONObject().put("id", id).put("plugin", plugin))
      finish()
      return
    }
    if (plugin == null || id == null) {
      finish()
      return
    }
    if (intent.getBooleanExtra(EXTRA_DISMISS, false)) {
      cancel(context, plugin, id)
    }
    val data = JSONObject()
      .put("id", id)
      .put("action", intent.getStringExtra(EXTRA_ACTION))
      .put("kind", kind)
      .put("params", PluginJson.obj(intent.getStringExtra(EXTRA_PARAMS)))
      .put("reply", RemoteInput.getResultsFromIntent(intent)?.getCharSequence(REPLY_KEY)?.toString())
    val event = when (kind) {
      KIND_TAP -> "notification.tapped"
      KIND_DISMISS -> "notification.dismissed"
      else -> "notification.action"
    }
    PluginEvents.emit(event, JSONObject(data.toString()).put("plugin", plugin))
    val method = intent.getStringExtra(EXTRA_METHOD)
    if (method.isNullOrEmpty()) {
      finish()
      return
    }
    PluginRuntime.mainHandler.postDelayed({ finish() }, CALLBACK_TIMEOUT_MS)
    PluginRuntime.executor.execute {
      try {
        invoke(context, plugin, id, method, data)
      } finally {
        finish()
      }
    }
  }

  private fun invoke(context: Context, plugin: String, id: String, method: String, data: JSONObject) {
    val response = try {
      PluginRuntime.callPlugin(plugin, method, PluginRuntime.callInput("NotificationActionV1", data))
    } catch (error: Throwable) {
      Log.w(PluginRuntime.TAG, "Notification callback $plugin.$method failed", error)
      return
    }
    val json = PluginJson.parse(response) as? JSONObject ?: return
    try {
      if (json.optBoolean("cancel", false)) {
        cancel(context, plugin, id)
      }
      json.optJSONObject("notification")?.let { spec ->
        if (!spec.has("id")) {
          spec.put("id", id)
        }
        post(context, plugin, spec)
      }
    } catch (error: Throwable) {
      PluginCrashGuard.report(plugin, "notification response", error)
    }
    if (json.has("message") || json.has("actions") || json.has("ui")) {
      PluginNativeBridge.perform(plugin, json.toString())
    }
  }

  // ---- tasks ----------------------------------------------------------------------------------------------------

  /** Shows or updates the progress notification of task [id]. [progress] 0..1, null for indeterminate. */
  fun showTask(context: Context, id: String, plugin: String?, title: String, text: String?, progress: Double?, cancellable: Boolean) {
    ensureAppChannel(context, TASK_CHANNEL, "Tasks")
    val builder = Notification.Builder(context, TASK_CHANNEL)
      .setSmallIcon(R.drawable.notification_icon)
      .setContentTitle(title)
      .setOnlyAlertOnce(true)
      .setOngoing(true)
      .setShowWhen(false)
      .setContentIntent(PendingIntent.getActivity(context, requestCode("task", id), launchIntent(context), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
    if (text != null) {
      builder.setContentText(text)
    }
    if (progress == null) {
      builder.setProgress(0, 0, true)
    } else {
      builder.setProgress(1000, (progress.coerceIn(0.0, 1.0) * 1000).toInt(), false)
    }
    if (cancellable) {
      val cancel = broadcast(context, KIND_TASK_CANCEL, plugin, id, null, null, null, false, false)
      builder.addAction(
        Notification.Action.Builder(Icon.createWithResource(context, R.drawable.notification_icon), context.getString(android.R.string.cancel), cancel).build(),
      )
    }
    if (enabled(context)) {
      manager(context).notify(TASK_TAG, id.hashCode(), builder.build())
    }
  }

  /** Ends task [id]: removes its notification, or with [keep] replaces it with a dismissible final state. */
  fun finishTask(context: Context, id: String, title: String?, text: String?, success: Boolean, keep: Boolean) {
    if (!keep) {
      cancelTask(context, id)
      return
    }
    ensureAppChannel(context, TASK_CHANNEL, "Tasks")
    val builder = Notification.Builder(context, TASK_CHANNEL)
      .setSmallIcon(R.drawable.notification_icon)
      .setOnlyAlertOnce(true)
      .setAutoCancel(true)
      .setOngoing(false)
      .setContentIntent(PendingIntent.getActivity(context, requestCode("task", id), launchIntent(context), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
    builder.setContentTitle(title ?: if (success) "Done" else "Failed")
    if (text != null) {
      builder.setContentText(text)
    }
    if (enabled(context)) {
      manager(context).notify(TASK_TAG, id.hashCode(), builder.build())
    }
  }

  fun cancelTask(context: Context, id: String) {
    manager(context).cancel(TASK_TAG, id.hashCode())
  }

  /** Notification for foreground background work. */
  fun workNotification(context: Context, title: String, text: String?): Notification {
    ensureAppChannel(context, WORK_CHANNEL, "Plugin background work")
    val builder = Notification.Builder(context, WORK_CHANNEL)
      .setSmallIcon(R.drawable.notification_icon)
      .setContentTitle(title)
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setShowWhen(false)
      .setProgress(0, 0, true)
    if (text != null) {
      builder.setContentText(text)
    }
    return builder.build()
  }
}

/** Receives taps, actions and dismissals of plugin notifications and task cancels. Not exported. */
class PluginNotificationReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    if (intent.action != PluginNotifications.ACTION_EVENT) {
      return
    }
    PluginRuntime.ensureInit(context)
    val pending = goAsync()
    PluginNotifications.dispatch(context.applicationContext, intent) { pending.finish() }
  }
}
