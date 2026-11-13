package app.alextran.immich.plugins

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.Gravity
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import app.alextran.immich.plugins.api.FrameCallback
import app.alextran.immich.plugins.api.ImmichVideoOverlayPlugin
import app.alextran.immich.plugins.api.ImmichViewLifecycle
import app.alextran.immich.plugins.api.ImmichViewPlugin
import app.alextran.immich.plugins.api.Registration
import app.alextran.immich.plugins.api.ResultCallback
import app.alextran.immich.plugins.api.VideoSession
import app.alextran.immich.plugins.api.VideoSessionListener
import app.alextran.immich.plugins.api.VideoSessionsListener
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToInt

/**
 * Video sessions, native side. The app's video players register each playing video over the `immich/plugin_video`
 * channel with the Flutter platform view id of the player; the native side finds the player view through the engine's
 * platform views controller, captures frames from its SurfaceView (PixelCopy) or TextureView, and hosts a native
 * overlay layer exactly over the video surface.
 *
 * Dart to native: `registerSession {sessionId, viewId, assetId?, durationMs?, videoWidth?, videoHeight?}`,
 * `unregisterSession {sessionId}`, `position {sessionId, positionMs, playing, speed?, durationMs?, videoWidth?,
 * videoHeight?}`, `captureFrame {sessionId, width?, height?, format?, quality?, path?}`,
 * `attachOverlay {sessionId, plugin, view, params?}`, `detachOverlay {sessionId, plugin, view}`, `sessions`.
 * Native to Dart: `control {sessionId, action: play|pause|seek|speed|volume, value?}`.
 */
internal object PluginVideoSessions : MethodChannel.MethodCallHandler {
  const val CHANNEL = "immich/plugin_video"
  private const val MAX_FRAME_SIZE = 8192

  @Volatile
  private var channel: MethodChannel? = null

  @Volatile
  private var engine: FlutterEngine? = null

  private val sessions = ConcurrentHashMap<String, VideoSessionCore>()

  private class ListenerEntry(val plugin: String, val listener: VideoSessionsListener)

  private val listeners = CopyOnWriteArrayList<ListenerEntry>()
  private val frameCounter = AtomicInteger()

  val copyHandler: Handler by lazy {
    val thread = HandlerThread("plugin-video-copy").apply { start() }
    Handler(thread.looper)
  }

  private val frameRoot: File get() = File(PluginRuntime.context.cacheDir, "plugin_video")

  fun attach(engine: FlutterEngine) {
    this.engine = engine
    channel?.setMethodCallHandler(null)
    channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    val stale = frameRoot
    PluginRuntime.executor.execute { stale.deleteRecursively() }
  }

  fun detach() {
    sessions.values.toList().forEach { end(it) }
    channel?.setMethodCallHandler(null)
    channel = null
    engine = null
  }

  /** The Android view of Flutter platform view [viewId], or null. */
  fun findView(viewId: Int): View? {
    val engine = engine ?: return null
    return try {
      engine.platformViewsControllerDelegator.getPlatformViewById(viewId)
    } catch (_: Throwable) {
      null
    } ?: try {
      engine.platformViewsController.getPlatformViewById(viewId)
    } catch (_: Throwable) {
      null
    } ?: try {
      engine.platformViewsController2.getPlatformViewById(viewId)
    } catch (_: Throwable) {
      null
    }
  }

  fun all(): List<VideoSessionCore> = sessions.values.filter { it.isActive }

  fun get(sessionId: String): VideoSessionCore? = sessions[sessionId]?.takeIf { it.isActive }

  fun addListener(plugin: String, listener: VideoSessionsListener): Registration {
    val entry = ListenerEntry(plugin, listener)
    listeners.add(entry)
    return PluginRuntime.scope(plugin).track { listeners.remove(entry) }
  }

  fun removePlugin(plugin: String) {
    sessions.values.forEach { it.removePlugin(plugin) }
  }

  fun frameFile(sessionId: String, extension: String): File {
    val directory = File(frameRoot, sessionId.replace(Regex("[^A-Za-z0-9._-]"), "_")).apply { mkdirs() }
    return File(directory, "frame-${frameCounter.incrementAndGet()}.$extension")
  }

  fun frameDirectory(sessionId: String): File = File(frameRoot, sessionId.replace(Regex("[^A-Za-z0-9._-]"), "_"))

  fun control(sessionId: String, action: String, value: Any?) {
    PluginRuntime.runOnMain {
      channel?.invokeMethod("control", mapOf("sessionId" to sessionId, "action" to action, "value" to value))
    }
  }

  internal fun started(session: VideoSessionCore) {
    for (entry in listeners) {
      PluginCrashGuard.run(entry.plugin, "video session started") {
        entry.listener.onSessionStarted(ScopedVideoSession(entry.plugin, session))
      }
    }
  }

  private fun end(session: VideoSessionCore) {
    sessions.remove(session.sessionId, session)
    if (!session.isActive) {
      return
    }
    session.end()
    PluginRuntime.runOnMain {
      for (entry in listeners) {
        PluginCrashGuard.run(entry.plugin, "video session ended") {
          entry.listener.onSessionEnded(ScopedVideoSession(entry.plugin, session))
        }
      }
    }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      handle(call, result)
    } catch (error: Throwable) {
      result.error("video_session", error.message ?: error.toString(), null)
    }
  }

  private fun MethodCall.long(key: String): Long? = argument<Number>(key)?.toLong()

  private fun MethodCall.int(key: String): Int? = argument<Number>(key)?.toInt()

  private fun MethodCall.sessionOrThrow(): VideoSessionCore {
    val id = argument<String>("sessionId") ?: throw IllegalArgumentException("sessionId is required")
    return get(id) ?: throw IllegalStateException("Video session $id does not exist")
  }

  private fun handle(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "registerSession" -> {
        val sessionId = call.argument<String>("sessionId") ?: throw IllegalArgumentException("sessionId is required")
        val viewId = call.int("viewId") ?: throw IllegalArgumentException("viewId is required")
        sessions[sessionId]?.let { end(it) }
        val session = VideoSessionCore(sessionId, viewId, call.argument<String>("assetId"))
        session.update(null, null, null, call.long("durationMs"), call.int("videoWidth"), call.int("videoHeight"))
        sessions[sessionId] = session
        session.bind()
        result.success(session.describe())
      }

      "unregisterSession" -> {
        val sessionId = call.argument<String>("sessionId") ?: throw IllegalArgumentException("sessionId is required")
        sessions[sessionId]?.let { end(it) }
        result.success(null)
      }

      "position" -> {
        val sessionId = call.argument<String>("sessionId") ?: throw IllegalArgumentException("sessionId is required")
        get(sessionId)?.update(
          call.long("positionMs"),
          call.argument<Boolean>("playing"),
          call.argument<Number>("speed")?.toDouble(),
          call.long("durationMs"),
          call.int("videoWidth"),
          call.int("videoHeight"),
        )
        result.success(null)
      }

      "captureFrame" -> {
        val session = call.sessionOrThrow()
        session.captureToFile(
          call.int("width") ?: 0,
          call.int("height") ?: 0,
          call.argument<String>("format") ?: "rgba",
          call.int("quality") ?: 90,
          call.argument<String>("path"),
        ) { json, error ->
          PluginRuntime.runOnMain {
            if (json != null) {
              result.success(PluginJson.fromJson(json))
            } else {
              result.error("capture_failed", error ?: "Frame capture failed", null)
            }
          }
        }
      }

      "attachOverlay" -> {
        val session = call.sessionOrThrow()
        val plugin = call.argument<String>("plugin") ?: throw IllegalArgumentException("plugin is required")
        val view = call.argument<String>("view") ?: throw IllegalArgumentException("view is required")
        val params = when (val value = call.argument<Any>("params")) {
          is String -> value
          null -> "{}"
          else -> PluginJson.stringify(value)
        }
        session.attachPluginOverlay(plugin, view, params)
        result.success(null)
      }

      "detachOverlay" -> {
        val session = call.sessionOrThrow()
        session.detachPluginOverlay(
          call.argument<String>("plugin") ?: throw IllegalArgumentException("plugin is required"),
          call.argument<String>("view") ?: throw IllegalArgumentException("view is required"),
        )
        result.success(null)
      }

      "sessions" -> result.success(all().map { it.describe() })

      else -> result.notImplemented()
    }
  }

  // ---- frames ---------------------------------------------------------------------------------------------------

  fun writeFrame(bitmap: Bitmap, format: String, quality: Int, file: File) {
    file.parentFile?.mkdirs()
    when (format) {
      "png" -> FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
      "jpeg" -> FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), it) }
      else -> {
        val rowBytes = bitmap.rowBytes
        val packed = bitmap.width * 4
        val buffer = ByteBuffer.allocate(rowBytes * bitmap.height)
        bitmap.copyPixelsToBuffer(buffer)
        FileOutputStream(file).use { output ->
          if (rowBytes == packed) {
            output.write(buffer.array(), 0, packed * bitmap.height)
          } else {
            for (row in 0 until bitmap.height) {
              output.write(buffer.array(), row * rowBytes, packed)
            }
          }
        }
      }
    }
  }

  fun targetSize(width: Int, height: Int, sourceWidth: Int, sourceHeight: Int): Pair<Int, Int> {
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return (width.coerceAtLeast(0)) to (height.coerceAtLeast(0))
    }
    val (w, h) = when {
      width > 0 && height > 0 -> width to height
      width > 0 -> width to (width.toDouble() * sourceHeight / sourceWidth).roundToInt()
      height > 0 -> (height.toDouble() * sourceWidth / sourceHeight).roundToInt() to height
      else -> sourceWidth to sourceHeight
    }
    return w.coerceIn(1, MAX_FRAME_SIZE) to h.coerceIn(1, MAX_FRAME_SIZE)
  }
}

/** One video session; plugins see it through [ScopedVideoSession]. */
internal class VideoSessionCore(
  override val sessionId: String,
  override val viewId: Int,
  override val assetId: String?,
) : VideoSession {
  private class Overlay(val plugin: String, val view: View, val holder: View, val viewType: String?)

  private class ListenerEntry(val plugin: String, val listener: VideoSessionListener)

  private val overlays = CopyOnWriteArrayList<Overlay>()
  private val listeners = CopyOnWriteArrayList<ListenerEntry>()

  @Volatile
  private var active = true

  @Volatile
  private var root: View? = null

  @Volatile
  private var surface: View? = null

  private var layer: FrameLayout? = null
  private var layerTracksSurface = false
  private var bindAttempts = 0
  private var startedNotified = false

  private var lastPosition = 0L
  private var lastUpdate = SystemClock.elapsedRealtime()
  private var playing = false
  private var speed = 1.0
  private var duration = -1L
  private var width = 0
  private var height = 0
  private val frame = Rect()
  private val frameOnScreen = Rect()

  private val layoutListener = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> updateFrame() }

  override val isActive: Boolean get() = active

  override val positionMs: Long
    get() = synchronized(this) { currentPosition() }

  private fun currentPosition(): Long {
    if (!playing) {
      return lastPosition
    }
    val position = lastPosition + ((SystemClock.elapsedRealtime() - lastUpdate) * speed).toLong()
    return if (duration > 0) position.coerceAtMost(duration) else position
  }

  override val durationMs: Long get() = synchronized(this) { duration }
  override val isPlaying: Boolean get() = synchronized(this) { playing }
  override val playbackSpeed: Double get() = synchronized(this) { speed }
  override val videoWidth: Int get() = synchronized(this) { width }
  override val videoHeight: Int get() = synchronized(this) { height }
  override val frameRect: Rect get() = synchronized(this) { Rect(frame) }
  override val frameRectOnScreen: Rect get() = synchronized(this) { Rect(frameOnScreen) }
  override val playerView: View? get() = root

  override val overlayContainer: ViewGroup?
    get() = if (PluginRuntime.isMainThread) ensureLayer() else layer

  fun describe(): Map<String, Any?> {
    val rect = frameRect
    return mapOf(
      "sessionId" to sessionId,
      "viewId" to viewId,
      "assetId" to assetId,
      "bound" to (root != null),
      "surface" to when (surface) {
        is SurfaceView -> "surfaceView"
        is TextureView -> "textureView"
        else -> null
      },
      "frame" to mapOf("left" to rect.left, "top" to rect.top, "width" to rect.width(), "height" to rect.height()),
      "positionMs" to positionMs,
      "playing" to isPlaying,
    )
  }

  // ---- binding to the player view --------------------------------------------------------------------------------

  /** Finds the player view and its surface; retries for up to two seconds while the platform view is created. */
  fun bind() {
    PluginRuntime.runOnMain {
      if (!active || root != null) {
        return@runOnMain
      }
      val view = PluginVideoSessions.findView(viewId)
      if (view == null) {
        if (++bindAttempts < 20) {
          PluginRuntime.mainHandler.postDelayed({ bind() }, 100)
        } else {
          notifyStarted()
        }
        return@runOnMain
      }
      root = view
      surface = findSurface(view)
      view.addOnLayoutChangeListener(layoutListener)
      surface?.addOnLayoutChangeListener(layoutListener)
      updateFrame()
      notifyStarted()
    }
  }

  private fun notifyStarted() {
    if (!startedNotified && active) {
      startedNotified = true
      PluginVideoSessions.started(this)
    }
  }

  private fun findSurface(view: View): View? {
    var best: View? = null
    var bestArea = -1L
    fun visit(current: View) {
      if (current is SurfaceView || current is TextureView) {
        val area = current.width.toLong() * current.height.toLong()
        if (area > bestArea) {
          best = current
          bestArea = area
        }
        return
      }
      if (current is ViewGroup) {
        for (index in 0 until current.childCount) {
          visit(current.getChildAt(index))
        }
      }
    }
    visit(view)
    return best
  }

  private fun updateFrame() {
    val target = surface ?: return
    val player = root ?: return
    if (target.parent == null) {
      surface = findSurface(player)?.also { it.addOnLayoutChangeListener(layoutListener) }
      return
    }
    val surfaceLocation = IntArray(2)
    val rootLocation = IntArray(2)
    target.getLocationInWindow(surfaceLocation)
    player.getLocationInWindow(rootLocation)
    val left = surfaceLocation[0] - rootLocation[0]
    val top = surfaceLocation[1] - rootLocation[1]
    val inPlayer = Rect(left, top, left + target.width, top + target.height)
    target.getLocationOnScreen(surfaceLocation)
    val onScreen = Rect(surfaceLocation[0], surfaceLocation[1], surfaceLocation[0] + target.width, surfaceLocation[1] + target.height)
    val changed = synchronized(this) {
      val changed = inPlayer != frame || onScreen != frameOnScreen
      frame.set(inPlayer)
      frameOnScreen.set(onScreen)
      changed
    }
    positionLayer()
    if (changed) {
      for (entry in listeners) {
        PluginCrashGuard.run(entry.plugin, "video frame listener") {
          entry.listener.onFrameRectChanged(ScopedVideoSession(entry.plugin, this), Rect(inPlayer))
        }
      }
    }
  }

  // ---- overlay layer --------------------------------------------------------------------------------------------

  /** Main thread. The layer above the video surface, sized to it. */
  private fun ensureLayer(): FrameLayout? {
    layer?.let { return it }
    if (!active) {
      return null
    }
    val target = surface ?: return null
    val parent = target.parent as? FrameLayout
    val params = target.layoutParams
    val margins = params as? ViewGroup.MarginLayoutParams
    val fillsParent = params != null &&
      params.width == ViewGroup.LayoutParams.MATCH_PARENT &&
      params.height == ViewGroup.LayoutParams.MATCH_PARENT &&
      (margins == null || (margins.leftMargin == 0 && margins.topMargin == 0 && margins.rightMargin == 0 && margins.bottomMargin == 0))
    val created = FrameLayout(target.context).apply {
      isClickable = false
      isFocusable = false
    }
    if (parent != null && fillsParent) {
      parent.addView(
        created,
        parent.indexOfChild(target) + 1,
        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
      )
      layerTracksSurface = false
    } else {
      val host = root as? FrameLayout ?: parent ?: return null
      host.addView(
        created,
        FrameLayout.LayoutParams(target.width.coerceAtLeast(0), target.height.coerceAtLeast(0)).apply {
          gravity = Gravity.TOP or Gravity.START
        },
      )
      layerTracksSurface = true
    }
    layer = created
    positionLayer()
    return created
  }

  private fun positionLayer() {
    if (!layerTracksSurface) {
      return
    }
    val overlay = layer ?: return
    val host = overlay.parent as? View ?: return
    val target = surface ?: return
    val surfaceLocation = IntArray(2)
    val hostLocation = IntArray(2)
    target.getLocationInWindow(surfaceLocation)
    host.getLocationInWindow(hostLocation)
    val params = overlay.layoutParams as? FrameLayout.LayoutParams ?: return
    val left = surfaceLocation[0] - hostLocation[0]
    val top = surfaceLocation[1] - hostLocation[1]
    if (params.leftMargin != left || params.topMargin != top || params.width != target.width || params.height != target.height) {
      params.leftMargin = left
      params.topMargin = top
      params.width = target.width
      params.height = target.height
      overlay.post { overlay.layoutParams = params }
    }
  }

  /** Main thread. */
  fun addOverlay(plugin: String, view: View, viewType: String?): Boolean {
    if (!PluginRuntime.isMainThread) {
      PluginRuntime.mainHandler.post { addOverlay(plugin, view, viewType) }
      return root != null
    }
    val overlay = ensureLayer() ?: return false
    (view.parent as? ViewGroup)?.removeView(view)
    val holder = PluginViewContainer(overlay.context, plugin, viewType ?: "overlay", -1)
    holder.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    overlay.addView(holder, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    overlays.add(Overlay(plugin, view, holder, viewType))
    return true
  }

  fun removeOverlay(plugin: String?, view: View) {
    val entry = overlays.firstOrNull { it.view === view && (plugin == null || it.plugin == plugin) } ?: return
    removeEntry(entry)
  }

  private fun removeEntry(entry: Overlay) {
    if (!overlays.remove(entry)) {
      return
    }
    PluginRuntime.runOnMain {
      (entry.holder.parent as? ViewGroup)?.removeView(entry.holder)
      (entry.view.parent as? ViewGroup)?.removeView(entry.view)
      val type = entry.viewType ?: return@runOnMain
      val instance = PluginRuntime.plugin(entry.plugin)
      PluginCrashGuard.run(entry.plugin, "video overlay removed") {
        if (instance is ImmichVideoOverlayPlugin) {
          instance.onVideoOverlayRemoved(type, entry.view, ScopedVideoSession(entry.plugin, this))
        } else if (instance is ImmichViewLifecycle) {
          instance.onViewDisposed(type, entry.view)
        }
      }
    }
  }

  /** Creates plugin view [viewType] (ImmichVideoOverlayPlugin or ImmichViewPlugin) and places it over the video. */
  fun attachPluginOverlay(plugin: String, viewType: String, paramsJson: String) {
    val instance = PluginRuntime.plugin(plugin) ?: throw IllegalStateException("Plugin $plugin is not loaded")
    val player = root ?: throw IllegalStateException("The video player view is not available yet")
    val params = PluginJson.obj(paramsJson)
      .put("session", JSONObject().put("id", sessionId).put("assetId", assetId).put("viewId", viewId))
      .toString()
    val context = PluginLifecycle.currentActivity ?: player.context
    val host = PluginRuntime.host(plugin)
    val scoped = ScopedVideoSession(plugin, this)
    val view = when (instance) {
      is ImmichVideoOverlayPlugin -> instance.createVideoOverlay(context, viewType, params, scoped, host)
      is ImmichViewPlugin -> instance.createView(context, viewType, params, host)
      else -> throw IllegalStateException("Plugin $plugin has no views")
    }
    detachPluginOverlay(plugin, viewType)
    if (!addOverlay(plugin, view, viewType)) {
      throw IllegalStateException("The video has no surface to place an overlay on")
    }
  }

  fun detachPluginOverlay(plugin: String, viewType: String) {
    overlays.filter { it.plugin == plugin && it.viewType == viewType }.forEach { removeEntry(it) }
  }

  fun removePlugin(plugin: String) {
    overlays.filter { it.plugin == plugin }.forEach { removeEntry(it) }
    listeners.removeIf { it.plugin == plugin }
  }

  // ---- state ----------------------------------------------------------------------------------------------------

  fun update(positionMs: Long?, playing: Boolean?, speed: Double?, durationMs: Long?, videoWidth: Int?, videoHeight: Int?) {
    val now = SystemClock.elapsedRealtime()
    val position: Long
    val isPlaying: Boolean
    synchronized(this) {
      if (positionMs != null) {
        lastPosition = positionMs
        lastUpdate = now
      } else if ((playing != null && playing != this.playing) || (speed != null && speed != this.speed)) {
        lastPosition = currentPosition()
        lastUpdate = now
      }
      playing?.let { this.playing = it }
      speed?.let { this.speed = it }
      durationMs?.let { duration = it }
      videoWidth?.let { width = it }
      videoHeight?.let { height = it }
      position = currentPosition()
      isPlaying = this.playing
    }
    if (listeners.isEmpty() || (positionMs == null && playing == null)) {
      return
    }
    PluginRuntime.runOnMain {
      for (entry in listeners) {
        PluginCrashGuard.run(entry.plugin, "video position listener") {
          entry.listener.onPosition(ScopedVideoSession(entry.plugin, this), position, isPlaying)
        }
      }
    }
  }

  fun addListener(plugin: String, listener: VideoSessionListener): Registration {
    val entry = ListenerEntry(plugin, listener)
    listeners.add(entry)
    return PluginRuntime.scope(plugin).track { listeners.remove(entry) }
  }

  fun end() {
    if (!active) {
      return
    }
    active = false
    val directory = PluginVideoSessions.frameDirectory(sessionId)
    PluginRuntime.runOnMain {
      root?.removeOnLayoutChangeListener(layoutListener)
      surface?.removeOnLayoutChangeListener(layoutListener)
      overlays.toList().forEach { removeEntry(it) }
      layer?.let { (it.parent as? ViewGroup)?.removeView(it) }
      layer = null
      for (entry in listeners) {
        PluginCrashGuard.run(entry.plugin, "video session end listener") {
          entry.listener.onEnded(ScopedVideoSession(entry.plugin, this))
        }
      }
      listeners.clear()
      root = null
      surface = null
    }
    PluginRuntime.executor.execute { directory.deleteRecursively() }
  }

  // ---- frame capture --------------------------------------------------------------------------------------------

  /** [callback] runs on a background thread and owns the bitmap. */
  fun capture(width: Int, height: Int, callback: (Bitmap?, String?) -> Unit) {
    val fail = { message: String -> PluginRuntime.executor.execute { callback(null, message) } }
    PluginRuntime.runOnMain {
      val target = surface
      if (!active || target == null) {
        fail("The video has no surface")
        return@runOnMain
      }
      val (sourceWidth, sourceHeight) = synchronized(this) {
        if (this.width > 0 && this.height > 0) this.width to this.height else target.width to target.height
      }
      val (w, h) = PluginVideoSessions.targetSize(width, height, sourceWidth, sourceHeight)
      if (w <= 0 || h <= 0) {
        fail("The video has no size yet")
        return@runOnMain
      }
      when (target) {
        is TextureView -> {
          val bitmap = try {
            target.getBitmap(w, h)
          } catch (error: Throwable) {
            null
          }
          PluginRuntime.executor.execute { callback(bitmap, if (bitmap == null) "The video frame is not available" else null) }
        }

        is SurfaceView -> {
          val holderSurface = target.holder.surface
          if (holderSurface == null || !holderSurface.isValid) {
            fail("The video surface is not ready")
            return@runOnMain
          }
          val bitmap = try {
            Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
          } catch (error: Throwable) {
            fail("Unable to allocate a ${w}x$h frame: ${error.message}")
            return@runOnMain
          }
          try {
            PixelCopy.request(target, bitmap, { copyResult ->
              if (copyResult == PixelCopy.SUCCESS) {
                PluginRuntime.executor.execute { callback(bitmap, null) }
              } else {
                bitmap.recycle()
                fail("PixelCopy failed ($copyResult)")
              }
            }, PluginVideoSessions.copyHandler)
          } catch (error: Throwable) {
            bitmap.recycle()
            fail("PixelCopy failed: ${error.message}")
          }
        }

        else -> fail("Unsupported video surface")
      }
    }
  }

  /** [callback] gets `{ path, width, height, format, positionMs }` or an error, on a background thread. */
  fun captureToFile(width: Int, height: Int, format: String, quality: Int, path: String?, callback: (JSONObject?, String?) -> Unit) {
    val normalized = when (format.lowercase()) {
      "png" -> "png"
      "jpg", "jpeg" -> "jpeg"
      else -> "rgba"
    }
    capture(width, height) { bitmap, error ->
      if (bitmap == null) {
        callback(null, error ?: "Frame capture failed")
        return@capture
      }
      try {
        val file = path?.let(::File) ?: PluginVideoSessions.frameFile(sessionId, if (normalized == "jpeg") "jpg" else normalized)
        PluginVideoSessions.writeFrame(bitmap, normalized, quality, file)
        callback(
          JSONObject()
            .put("path", file.absolutePath)
            .put("width", bitmap.width)
            .put("height", bitmap.height)
            .put("format", normalized)
            .put("positionMs", positionMs),
          null,
        )
      } catch (failure: Throwable) {
        callback(null, failure.message ?: failure.toString())
      } finally {
        bitmap.recycle()
      }
    }
  }

  // ---- VideoSession (owner-less use; plugins get ScopedVideoSession) ---------------------------------------------

  override fun addOverlay(view: View): Boolean = addOverlay("app", view, null)

  override fun removeOverlay(view: View) = removeOverlay(null, view)

  override fun captureFrame(width: Int, height: Int, callback: FrameCallback) =
    capture(width, height) { bitmap, error -> callback.onFrame(bitmap, error) }

  override fun captureFrameToFile(width: Int, height: Int, format: String, callback: ResultCallback) =
    captureToFile(width, height, format, 90, null) { json, error ->
      callback.onResult(if (json != null) PluginJson.ok(json.toString()) else PluginJson.error(500, error ?: "Frame capture failed"))
    }

  override fun addListener(listener: VideoSessionListener): Registration = addListener("app", listener)

  override fun play() = PluginVideoSessions.control(sessionId, "play", null)

  override fun pause() = PluginVideoSessions.control(sessionId, "pause", null)

  override fun seekTo(positionMs: Long) = PluginVideoSessions.control(sessionId, "seek", positionMs)

  override fun setSpeed(speed: Double) = PluginVideoSessions.control(sessionId, "speed", speed)

  override fun setVolume(volume: Double) = PluginVideoSessions.control(sessionId, "volume", volume)
}

/** The view of a session one plugin gets: overlays and listeners it adds are owned by it. */
internal class ScopedVideoSession(
  private val plugin: String,
  private val core: VideoSessionCore,
) : VideoSession by core {
  override fun addOverlay(view: View): Boolean = core.addOverlay(plugin, view, null)

  override fun removeOverlay(view: View) = core.removeOverlay(plugin, view)

  override fun addListener(listener: VideoSessionListener): Registration = core.addListener(plugin, listener)

  override fun captureFrame(width: Int, height: Int, callback: FrameCallback) =
    core.capture(width, height) { bitmap, error ->
      PluginCrashGuard.run(plugin, "frame callback") { callback.onFrame(bitmap, error) }
    }

  override fun captureFrameToFile(width: Int, height: Int, format: String, callback: ResultCallback) =
    core.captureToFile(width, height, format, 90, null) { json, error ->
      val envelope = if (json != null) PluginJson.ok(json.toString()) else PluginJson.error(500, error ?: "Frame capture failed")
      PluginCrashGuard.run(plugin, "frame callback") { callback.onResult(envelope) }
    }

  override fun equals(other: Any?): Boolean = other is ScopedVideoSession && other.core === core && other.plugin == plugin

  override fun hashCode(): Int = core.hashCode() * 31 + plugin.hashCode()
}
