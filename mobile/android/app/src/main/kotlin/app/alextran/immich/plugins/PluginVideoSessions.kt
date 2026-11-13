package app.alextran.immich.plugins

import android.graphics.Bitmap
import android.graphics.Rect
import android.media.MediaMetadataRetriever
import android.os.Build
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
import app.alextran.immich.plugins.PluginJson.str
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
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToInt

/**
 * Video sessions, native side of `MethodChannel("immich/plugin_video")` (Dart client: `PluginVideoChannel` in
 * `plugin_api/viewer/video_sessions.dart`, protocol in docs/plugins/viewer.md and native.md).
 *
 * Every call carries `{ sessionId, viewId, assetId, localId, remoteId, surface }`; the player view is found with the
 * engine's platform views controller (native_video_player: FrameLayout > AspectRatioFrameLayout > SurfaceView).
 * Methods: `registerSession` and `updateSession` (+ state fields `state, positionMs, durationMs, speed, volume,
 * videoWidth, videoHeight, frameRect, devicePixelRatio`), `unregisterSession`, `captureFrame`, `extractFrame`,
 * `attachOverlay`, `detachOverlay`, and `sessions` (diagnostics).
 */
internal object PluginVideoSessions : MethodChannel.MethodCallHandler {
  const val CHANNEL = "immich/plugin_video"
  private const val MAX_FRAME_SIZE = 8192
  private const val KEPT_EXTRACTED_FRAMES = 32

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

  /** While any listener exists, Dart registers every player natively as soon as it exists. */
  fun addListener(plugin: String, listener: VideoSessionsListener): Registration {
    val entry = ListenerEntry(plugin, listener)
    listeners.add(entry)
    PluginNativeBridge.videoSessionsWanted(true)
    return PluginRuntime.scope(plugin).track {
      listeners.remove(entry)
      PluginNativeBridge.videoSessionsWanted(listeners.isNotEmpty())
    }
  }

  val wanted: Boolean get() = listeners.isNotEmpty()

  fun removePlugin(plugin: String) {
    sessions.values.forEach { it.removePlugin(plugin) }
  }

  private fun safeName(text: String) = text.replace(Regex("[^A-Za-z0-9._-]"), "_")

  fun frameDirectory(sessionId: String): File = File(frameRoot, safeName(sessionId))

  fun frameFile(sessionId: String, extension: String): File {
    val directory = frameDirectory(sessionId).apply { mkdirs() }
    return File(directory, "frame-${frameCounter.incrementAndGet()}.$extension")
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

  // ---- channel --------------------------------------------------------------------------------------------------

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      handle(call, result)
    } catch (error: Throwable) {
      result.error("video_session", error.message ?: error.toString(), null)
    }
  }

  private fun MethodCall.long(key: String): Long? = argument<Number>(key)?.toLong()

  private fun MethodCall.int(key: String): Int? = argument<Number>(key)?.toInt()

  private fun MethodCall.double(key: String): Double? = argument<Number>(key)?.toDouble()

  private fun MethodCall.sessionId(): String = argument<String>("sessionId") ?: throw IllegalArgumentException("sessionId is required")

  /** The session of this call; created (and bound to its player view) when it is not registered yet. */
  private fun sessionFor(call: MethodCall): VideoSessionCore {
    val sessionId = call.sessionId()
    val viewId = call.int("viewId") ?: throw IllegalArgumentException("viewId is required")
    val existing = get(sessionId)
    if (existing != null && existing.viewId == viewId) {
      existing.identify(call.argument("assetId"), call.argument("localId"), call.argument("remoteId"), call.argument("surface"))
      return existing
    }
    existing?.let { end(it) }
    val session = VideoSessionCore(sessionId, viewId)
    session.identify(call.argument("assetId"), call.argument("localId"), call.argument("remoteId"), call.argument("surface"))
    sessions[sessionId] = session
    session.bind()
    return session
  }

  private fun applyState(session: VideoSessionCore, call: MethodCall) {
    val frame = call.argument<Map<String, Any?>>("frameRect")
    session.update(
      positionMs = call.long("positionMs"),
      state = call.argument("state"),
      speed = call.double("speed"),
      volume = call.double("volume"),
      durationMs = call.long("durationMs"),
      videoWidth = call.int("videoWidth"),
      videoHeight = call.int("videoHeight"),
      logicalFrame = frame?.let {
        val left = (it["left"] as? Number)?.toDouble() ?: 0.0
        val top = (it["top"] as? Number)?.toDouble() ?: 0.0
        val width = (it["width"] as? Number)?.toDouble() ?: 0.0
        val height = (it["height"] as? Number)?.toDouble() ?: 0.0
        doubleArrayOf(left, top, width, height)
      },
      devicePixelRatio = call.double("devicePixelRatio"),
    )
  }

  private fun handle(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "registerSession" -> {
        applyState(sessionFor(call), call)
        result.success(null)
      }

      "updateSession" -> {
        get(call.sessionId())?.let { applyState(it, call) }
        result.success(null)
      }

      "unregisterSession" -> {
        sessions[call.sessionId()]?.let { end(it) }
        result.success(null)
      }

      "captureFrame" -> {
        val session = sessionFor(call)
        session.captureToFile(
          call.int("width") ?: 0,
          call.int("height") ?: 0,
          call.argument<String>("format") ?: "rgba",
          call.int("quality") ?: 90,
          null,
          call.long("positionMs"),
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

      "extractFrame" -> {
        val options = JSONObject()
          .put("path", call.argument<String>("path"))
          .put("url", call.argument<String>("url"))
          .put("headers", PluginJson.toJson(call.argument<Map<String, Any?>>("headers") ?: emptyMap<String, Any?>()))
          .put("localId", call.argument<String>("localId"))
          .put("width", call.int("width") ?: 0)
          .put("height", call.int("height") ?: 0)
          .put("format", call.argument<String>("format") ?: "rgba")
          .put("quality", call.int("quality") ?: 90)
        extractFrame(call.long("timeMs") ?: 0, options) { json, error ->
          PluginRuntime.runOnMain {
            if (json != null) {
              result.success(PluginJson.fromJson(json))
            } else {
              result.error("extract_failed", error ?: "Frame extraction failed", null)
            }
          }
        }
      }

      "attachOverlay" -> {
        val session = sessionFor(call)
        applyState(session, call)
        val plugin = call.argument<String>("plugin") ?: throw IllegalArgumentException("plugin is required")
        val view = call.argument<String>("view") ?: throw IllegalArgumentException("view is required")
        val id = call.argument<String>("id") ?: view
        val params = when (val value = call.argument<Any>("params")) {
          null -> JSONObject()
          is String -> PluginJson.obj(value)
          else -> PluginJson.toJson(value) as? JSONObject ?: JSONObject()
        }
        session.attachPluginOverlay(plugin, view, id, params, call.argument<Boolean>("interactive") ?: false) { overlayId, error ->
          if (overlayId != null) {
            result.success(mapOf("overlayId" to overlayId))
          } else {
            result.error("overlay_failed", error ?: "The overlay could not be attached", null)
          }
        }
      }

      "detachOverlay" -> {
        val plugin = call.argument<String>("plugin") ?: throw IllegalArgumentException("plugin is required")
        get(call.sessionId())?.detachPluginOverlays(plugin, call.argument<String>("id"))
        result.success(null)
      }

      "sessions" -> result.success(all().map { it.describe() })

      else -> result.notImplemented()
    }
  }

  // ---- frames ---------------------------------------------------------------------------------------------------

  fun normalizeFormat(format: String?): String = when (format?.lowercase()) {
    "png" -> "png"
    "jpg", "jpeg" -> "jpeg"
    else -> "rgba"
  }

  fun extension(format: String): String = if (format == "jpeg") "jpg" else format

  fun writeFrame(source: Bitmap, format: String, quality: Int, file: File) {
    file.parentFile?.mkdirs()
    when (format) {
      "png" -> FileOutputStream(file).use { source.compress(Bitmap.CompressFormat.PNG, 100, it) }
      "jpeg" -> FileOutputStream(file).use { source.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), it) }
      else -> {
        val bitmap = if (source.config == Bitmap.Config.ARGB_8888) source else source.copy(Bitmap.Config.ARGB_8888, false)
        try {
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
        } finally {
          if (bitmap !== source) {
            bitmap.recycle()
          }
        }
      }
    }
  }

  /** The output size for a request of [width] x [height] (0 = derive) from a source of the given size. */
  fun targetSize(width: Int, height: Int, sourceWidth: Int, sourceHeight: Int): Pair<Int, Int> {
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return width.coerceAtLeast(0) to height.coerceAtLeast(0)
    }
    val (w, h) = when {
      width > 0 && height > 0 -> width to height
      width > 0 -> width to (width.toDouble() * sourceHeight / sourceWidth).roundToInt()
      height > 0 -> (height.toDouble() * sourceWidth / sourceHeight).roundToInt() to height
      else -> sourceWidth to sourceHeight
    }
    return w.coerceIn(1, MAX_FRAME_SIZE) to h.coerceIn(1, MAX_FRAME_SIZE)
  }

  /**
   * Decodes the frame at [timeMs] of a video file (`path`), URL (`url` + `headers`) or device video (`localId`)
   * with MediaMetadataRetriever (closest frame). [callback] on a background thread.
   */
  fun extractFrame(timeMs: Long, options: JSONObject, callback: (JSONObject?, String?) -> Unit) {
    PluginRuntime.executor.execute {
      val retriever = MediaMetadataRetriever()
      var frame: Bitmap? = null
      try {
        val path = options.str("path")
        val url = options.str("url")
        val localId = options.str("localId")
        when {
          path != null -> retriever.setDataSource(path)
          url != null -> {
            val headers = mutableMapOf<String, String>()
            options.optJSONObject("headers")?.let { json ->
              json.keys().forEach { key -> headers[key] = json.optString(key) }
            }
            retriever.setDataSource(url, headers)
          }
          localId != null -> retriever.setDataSource(PluginRuntime.context, PluginMedia.uri(localId, true))
          else -> throw IllegalArgumentException("extractFrame needs path, url or localId")
        }
        val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        var videoWidth = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
        var videoHeight = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
        if (rotation == 90 || rotation == 270) {
          videoWidth = videoHeight.also { videoHeight = videoWidth }
        }
        val requestedWidth = options.optInt("width", 0)
        val requestedHeight = options.optInt("height", 0)
        val timeUs = timeMs.coerceAtLeast(0) * 1000
        val sized = requestedWidth > 0 || requestedHeight > 0
        val (width, height) = targetSize(requestedWidth, requestedHeight, videoWidth, videoHeight)
        frame = if (sized && width > 0 && height > 0 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
          retriever.getScaledFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST, width, height)
        } else {
          retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
        }
        val decoded = frame ?: throw IllegalStateException("No frame at $timeMs ms")
        if (sized && width > 0 && height > 0 && (decoded.width != width || decoded.height != height)) {
          frame = Bitmap.createScaledBitmap(decoded, width, height, true)
          if (frame !== decoded) {
            decoded.recycle()
          }
        }
        val output = frame ?: decoded
        val format = normalizeFormat(options.str("format"))
        val directory = File(frameRoot, "extracted").apply { mkdirs() }
        val file = File(directory, "frame-${frameCounter.incrementAndGet()}.${extension(format)}")
        writeFrame(output, format, options.optInt("quality", 90), file)
        directory.listFiles()?.sortedByDescending { it.lastModified() }?.drop(KEPT_EXTRACTED_FRAMES)?.forEach { it.delete() }
        callback(
          JSONObject()
            .put("path", file.absolutePath)
            .put("width", output.width)
            .put("height", output.height)
            .put("format", format)
            .put("positionMs", timeMs),
          null,
        )
      } catch (error: Throwable) {
        callback(null, error.message ?: error.toString())
      } finally {
        frame?.recycle()
        try {
          retriever.release()
        } catch (_: Throwable) {
          // Already released.
        }
      }
    }
  }
}

/** One video session; plugins see it through [ScopedVideoSession]. */
internal class VideoSessionCore(
  override val sessionId: String,
  override val viewId: Int,
) : VideoSession {
  private class Overlay(val plugin: String, val id: String?, val view: View, val holder: PluginViewContainer, val viewType: String?)

  private class ListenerEntry(val plugin: String, val listener: VideoSessionListener)

  private val overlays = CopyOnWriteArrayList<Overlay>()
  private val listeners = CopyOnWriteArrayList<ListenerEntry>()

  @Volatile
  private var active = true

  @Volatile
  private var root: View? = null

  @Volatile
  private var surfaceView: View? = null

  @Volatile
  override var assetId: String? = null
    private set

  @Volatile
  override var localId: String? = null
    private set

  @Volatile
  override var remoteId: String? = null
    private set

  @Volatile
  override var appSurface: String? = null
    private set

  private var layer: FrameLayout? = null
  private var layerTracksSurface = false
  private var bindAttempts = 0
  private var startedNotified = false

  private var lastPosition = 0L
  private var lastUpdate = SystemClock.elapsedRealtime()
  private var currentState = "loading"
  private var speed = 1.0
  private var currentVolume = 1.0
  private var duration = -1L
  private var width = 0
  private var height = 0
  private var logicalFrame: DoubleArray? = null
  private var pixelRatio = 1.0
  private val frame = Rect()
  private val frameOnScreen = Rect()

  private val layoutListener = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> updateFrame() }

  fun identify(assetId: String?, localId: String?, remoteId: String?, surface: String?) {
    assetId?.let { this.assetId = it }
    localId?.let { this.localId = it }
    remoteId?.let { this.remoteId = it }
    surface?.let { this.appSurface = it }
  }

  override val isActive: Boolean get() = active

  private val playing: Boolean get() = currentState == "playing"

  override val positionMs: Long
    get() = synchronized(this) { currentPosition() }

  private fun currentPosition(): Long {
    if (!playing) {
      return lastPosition
    }
    val position = lastPosition + ((SystemClock.elapsedRealtime() - lastUpdate) * speed).toLong()
    return if (duration > 0) position.coerceAtMost(duration) else position
  }

  override val state: String get() = synchronized(this) { currentState }
  override val volume: Double get() = synchronized(this) { currentVolume }
  override val durationMs: Long get() = synchronized(this) { duration }
  override val isPlaying: Boolean get() = synchronized(this) { playing }
  override val playbackSpeed: Double get() = synchronized(this) { speed }
  override val videoWidth: Int get() = synchronized(this) { width }
  override val videoHeight: Int get() = synchronized(this) { height }
  override val frameRect: Rect get() = synchronized(this) { Rect(frame) }

  override val frameRectOnScreen: Rect
    get() = synchronized(this) {
      val logical = logicalFrame
      if (frameOnScreen.isEmpty && logical != null) {
        Rect(
          (logical[0] * pixelRatio).roundToInt(),
          (logical[1] * pixelRatio).roundToInt(),
          ((logical[0] + logical[2]) * pixelRatio).roundToInt(),
          ((logical[1] + logical[3]) * pixelRatio).roundToInt(),
        )
      } else {
        Rect(frameOnScreen)
      }
    }

  override val playerView: View? get() = root

  override val overlayContainer: ViewGroup?
    get() = if (PluginRuntime.isMainThread) ensureLayer() else layer

  fun describe(): Map<String, Any?> {
    val rect = frameRect
    return mapOf(
      "sessionId" to sessionId,
      "viewId" to viewId,
      "assetId" to assetId,
      "localId" to localId,
      "remoteId" to remoteId,
      "surface" to appSurface,
      "bound" to (root != null),
      "videoSurface" to when (surfaceView) {
        is SurfaceView -> "surfaceView"
        is TextureView -> "textureView"
        else -> null
      },
      "frame" to mapOf("left" to rect.left, "top" to rect.top, "width" to rect.width(), "height" to rect.height()),
      "state" to state,
      "positionMs" to positionMs,
      "overlays" to overlays.map { "${it.plugin}/${it.id ?: "native"}" },
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
      surfaceView = findSurface(view)
      view.addOnLayoutChangeListener(layoutListener)
      surfaceView?.addOnLayoutChangeListener(layoutListener)
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
    val target = surfaceView ?: return
    val player = root ?: return
    if (target.parent == null) {
      surfaceView = findSurface(player)?.also { it.addOnLayoutChangeListener(layoutListener) }
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

  /** Main thread. The layer above the video surface, sized to it (inside the AspectRatioFrameLayout). */
  private fun ensureLayer(): FrameLayout? {
    layer?.let { return it }
    if (!active) {
      return null
    }
    val target = surfaceView ?: return null
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
    val target = surfaceView ?: return
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

  /** Main thread (posts itself otherwise). Adds [view] over the video frame for [plugin]. */
  fun addOverlay(plugin: String, id: String?, view: View, viewType: String?, interactive: Boolean): Boolean {
    if (!PluginRuntime.isMainThread) {
      PluginRuntime.mainHandler.post { addOverlay(plugin, id, view, viewType, interactive) }
      return root != null
    }
    val overlay = ensureLayer() ?: return false
    (view.parent as? ViewGroup)?.removeView(view)
    val holder = PluginViewContainer(overlay.context, plugin, viewType ?: "overlay", -1)
    holder.touchable = interactive
    holder.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    overlay.addView(holder, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    overlays.add(Overlay(plugin, id, view, holder, viewType))
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

  /**
   * Creates view [viewType] of [plugin] and places it over the video as overlay [id] (replacing one with that id).
   * [callback] gets `<plugin>/<id>` or an error, on the main thread.
   */
  fun attachPluginOverlay(
    plugin: String,
    viewType: String,
    id: String,
    params: JSONObject,
    interactive: Boolean,
    callback: (String?, String?) -> Unit,
  ) {
    PluginRuntime.runOnMain {
      attachWhenBound(plugin, viewType, id, params, interactive, callback, attempts = 0)
    }
  }

  private fun attachWhenBound(
    plugin: String,
    viewType: String,
    id: String,
    params: JSONObject,
    interactive: Boolean,
    callback: (String?, String?) -> Unit,
    attempts: Int,
  ) {
    if (!active) {
      callback(null, "The video session ended")
      return
    }
    if (surfaceView == null) {
      if (attempts < 20) {
        PluginRuntime.mainHandler.postDelayed({ attachWhenBound(plugin, viewType, id, params, interactive, callback, attempts + 1) }, 100)
      } else {
        callback(null, "The video player has no surface to place an overlay on")
      }
      return
    }
    val instance = PluginRuntime.plugin(plugin)
    if (instance == null) {
      callback(null, "Plugin $plugin is not loaded")
      return
    }
    val overlayId = "$plugin/$id"
    val fullParams = JSONObject(params.toString())
      .put("sessionId", sessionId)
      .put("assetId", assetId)
      .put("viewId", viewId)
      .put("overlayId", overlayId)
      .toString()
    val context = root?.context ?: PluginRuntime.context
    val view = try {
      when (instance) {
        is ImmichVideoOverlayPlugin ->
          instance.createVideoOverlay(context, viewType, fullParams, ScopedVideoSession(plugin, this), PluginRuntime.host(plugin))
        is ImmichViewPlugin -> instance.createView(context, viewType, fullParams, PluginRuntime.host(plugin))
        else -> null
      }
    } catch (error: Throwable) {
      PluginCrashGuard.report(plugin, "video overlay $viewType", error)
      callback(null, "The plugin view failed: ${error.message ?: error}")
      return
    }
    if (view == null) {
      callback(null, "Plugin $plugin has no native views")
      return
    }
    detachPluginOverlays(plugin, id)
    if (addOverlay(plugin, id, view, viewType, interactive)) {
      callback(overlayId, null)
    } else {
      callback(null, "The video player has no surface to place an overlay on")
    }
  }

  /** Removes overlay [id] of [plugin], or all of the plugin's overlays when [id] is null. */
  fun detachPluginOverlays(plugin: String, id: String?) {
    overlays.filter { it.plugin == plugin && (id == null || it.id == id) }.forEach { removeEntry(it) }
  }

  fun removePlugin(plugin: String) {
    overlays.filter { it.plugin == plugin }.forEach { removeEntry(it) }
    listeners.removeIf { it.plugin == plugin }
  }

  // ---- state ----------------------------------------------------------------------------------------------------

  fun update(
    positionMs: Long?,
    state: String?,
    speed: Double?,
    volume: Double?,
    durationMs: Long?,
    videoWidth: Int?,
    videoHeight: Int?,
    logicalFrame: DoubleArray?,
    devicePixelRatio: Double?,
  ) {
    val now = SystemClock.elapsedRealtime()
    val position: Long
    val isPlaying: Boolean
    synchronized(this) {
      if (positionMs != null) {
        lastPosition = positionMs
        lastUpdate = now
      } else if ((state != null && state != currentState) || (speed != null && speed != this.speed)) {
        lastPosition = currentPosition()
        lastUpdate = now
      }
      state?.let { currentState = it }
      speed?.let { this.speed = it }
      volume?.let { currentVolume = it }
      durationMs?.let { duration = it }
      videoWidth?.let { width = it }
      videoHeight?.let { height = it }
      logicalFrame?.let { this.logicalFrame = it }
      devicePixelRatio?.let { pixelRatio = it }
      position = currentPosition()
      isPlaying = playing
    }
    if (positionMs == null && state == null) {
      return
    }
    PluginRuntime.runOnMain {
      if (root != null) {
        updateFrame()
      }
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
      surfaceView?.removeOnLayoutChangeListener(layoutListener)
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
      surfaceView = null
    }
    PluginRuntime.executor.execute { directory.deleteRecursively() }
  }

  /** Asks the app's player to [action] through the viewer's `video.*` host functions, as [plugin]. */
  fun control(plugin: String, function: String, value: Any?) {
    PluginRuntime.executor.execute {
      val args = JSONArray().put(sessionId)
      if (value != null) {
        args.put(value)
      }
      val response = PluginRuntime.host(plugin).callHost(function, args.toString())
      if (PluginJson.obj(response).optBoolean("success", false).not()) {
        PluginRuntime.log(android.util.Log.WARN, "Video control $function for $sessionId failed: $response")
      }
    }
  }

  // ---- frame capture --------------------------------------------------------------------------------------------

  /** [callback] runs on a background thread and owns the bitmap. */
  fun capture(width: Int, height: Int, callback: (Bitmap?, String?) -> Unit) {
    val fail = { message: String -> PluginRuntime.executor.execute { callback(null, message) } }
    PluginRuntime.runOnMain {
      captureWhenBound(width, height, callback, fail, attempts = 0)
    }
  }

  private fun captureWhenBound(width: Int, height: Int, callback: (Bitmap?, String?) -> Unit, fail: (String) -> Unit, attempts: Int) {
    val target = surfaceView
    if (!active) {
      fail("The video session ended")
      return
    }
    if (target == null) {
      if (attempts < 20) {
        PluginRuntime.mainHandler.postDelayed({ captureWhenBound(width, height, callback, fail, attempts + 1) }, 100)
      } else {
        fail("The video player has no surface")
      }
      return
    }
    val (sourceWidth, sourceHeight) = synchronized(this) {
      if (this.width > 0 && this.height > 0) this.width to this.height else target.width to target.height
    }
    val (w, h) = PluginVideoSessions.targetSize(width, height, sourceWidth, sourceHeight)
    if (w <= 0 || h <= 0) {
      fail("The video has no size yet")
      return
    }
    when (target) {
      is TextureView -> {
        val bitmap = try {
          target.getBitmap(w, h)
        } catch (_: Throwable) {
          null
        }
        PluginRuntime.executor.execute { callback(bitmap, if (bitmap == null) "The video frame is not available" else null) }
      }

      is SurfaceView -> {
        val holderSurface = target.holder.surface
        if (holderSurface == null || !holderSurface.isValid) {
          fail("The video surface is not ready")
          return
        }
        val bitmap = try {
          Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        } catch (error: Throwable) {
          fail("Unable to allocate a ${w}x$h frame: ${error.message}")
          return
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

  /** [callback] gets `{ path, width, height, format, positionMs }` or an error, on a background thread. */
  fun captureToFile(
    width: Int,
    height: Int,
    format: String,
    quality: Int,
    path: String?,
    positionOverride: Long?,
    callback: (JSONObject?, String?) -> Unit,
  ) {
    val normalized = PluginVideoSessions.normalizeFormat(format)
    val position = positionOverride ?: positionMs
    capture(width, height) { bitmap, error ->
      if (bitmap == null) {
        callback(null, error ?: "Frame capture failed")
        return@capture
      }
      try {
        val file = path?.let(::File) ?: PluginVideoSessions.frameFile(sessionId, PluginVideoSessions.extension(normalized))
        PluginVideoSessions.writeFrame(bitmap, normalized, quality, file)
        callback(
          JSONObject()
            .put("path", file.absolutePath)
            .put("width", bitmap.width)
            .put("height", bitmap.height)
            .put("format", normalized)
            .put("positionMs", position),
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

  override fun addOverlay(view: View): Boolean = addOverlay("app", null, view, null, false)

  override fun removeOverlay(view: View) = removeOverlay(null, view)

  override fun captureFrame(width: Int, height: Int, callback: FrameCallback) =
    capture(width, height) { bitmap, error -> callback.onFrame(bitmap, error) }

  override fun captureFrameToFile(width: Int, height: Int, format: String, callback: ResultCallback) =
    captureToFile(width, height, format, 90, null, null) { json, error ->
      callback.onResult(if (json != null) PluginJson.ok(json.toString()) else PluginJson.error(500, error ?: "Frame capture failed"))
    }

  override fun addListener(listener: VideoSessionListener): Registration = addListener("app", listener)

  override fun play() = control("app", "video.play", null)

  override fun pause() = control("app", "video.pause", null)

  override fun seekTo(positionMs: Long) = control("app", "video.seek", positionMs)

  override fun setSpeed(speed: Double) = control("app", "video.setSpeed", speed)

  override fun setVolume(volume: Double) = control("app", "video.setVolume", volume)
}

/** The view of a session one plugin gets: overlays, listeners and control calls are made as that plugin. */
internal class ScopedVideoSession(
  private val plugin: String,
  private val core: VideoSessionCore,
) : VideoSession by core {
  override fun addOverlay(view: View): Boolean = core.addOverlay(plugin, null, view, null, false)

  override fun removeOverlay(view: View) = core.removeOverlay(plugin, view)

  override fun addListener(listener: VideoSessionListener): Registration = core.addListener(plugin, listener)

  override fun captureFrame(width: Int, height: Int, callback: FrameCallback) =
    core.capture(width, height) { bitmap, error ->
      PluginCrashGuard.run(plugin, "frame callback") { callback.onFrame(bitmap, error) }
    }

  override fun captureFrameToFile(width: Int, height: Int, format: String, callback: ResultCallback) =
    core.captureToFile(width, height, format, 90, null, null) { json, error ->
      val envelope = if (json != null) PluginJson.ok(json.toString()) else PluginJson.error(500, error ?: "Frame capture failed")
      PluginCrashGuard.run(plugin, "frame callback") { callback.onResult(envelope) }
    }

  override fun play() = core.control(plugin, "video.play", null)

  override fun pause() = core.control(plugin, "video.pause", null)

  override fun seekTo(positionMs: Long) = core.control(plugin, "video.seek", positionMs)

  override fun setSpeed(speed: Double) = core.control(plugin, "video.setSpeed", speed)

  override fun setVolume(volume: Double) = core.control(plugin, "video.setVolume", volume)

  override fun equals(other: Any?): Boolean = other is ScopedVideoSession && other.core === core && other.plugin == plugin

  override fun hashCode(): Int = core.hashCode() * 31 + plugin.hashCode()
}
