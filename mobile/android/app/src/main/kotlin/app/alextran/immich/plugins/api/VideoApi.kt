package app.alextran.immich.plugins.api

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup

/**
 * Video sessions: the videos the app plays (viewer, memories, slideshow, ...). The app registers a player natively
 * when something needs it (a capture, a native overlay) and, while any plugin has a [VideoSessionsListener], every
 * player as soon as it exists.
 */
interface NativeVideo {
  val sessions: List<VideoSession>

  fun session(sessionId: String): VideoSession?

  fun addListener(listener: VideoSessionsListener): Registration

  /**
   * Decodes the frame at [timeMs] of a video without a player. [optionsJson]: `{ path? | url? + headers? | localId?,
   * width?, height?, format?: rgba|png|jpeg, quality? }`. Result `{ path, width, height, format, positionMs }`.
   */
  fun extractFrame(timeMs: Long, optionsJson: String, callback: ResultCallback)
}

/** Main thread. */
interface VideoSessionsListener {
  fun onSessionStarted(session: VideoSession) {}

  fun onSessionEnded(session: VideoSession) {}
}

/**
 * A playing video. Properties may be read from any thread. View access ([playerView], [overlayContainer]) on the
 * main thread only.
 */
interface VideoSession {
  val sessionId: String

  /** Asset id of the video (the app's id: remote id for server assets, local id otherwise). */
  val assetId: String?

  /** Device (MediaStore) id, if the video is on the device. */
  val localId: String?

  /** Server id, if the video is on the server. */
  val remoteId: String?

  /** The app surface playing it: `viewer`, `slideshow`, `memory`, ... */
  val appSurface: String?

  /** Flutter platform view id of the player. */
  val viewId: Int

  /** False after the session ended. */
  val isActive: Boolean

  /** `loading`, `ready`, `playing`, `paused`, `buffering`, `completed` or `error`. */
  val state: String

  /** 0..1. */
  val volume: Double

  /** Playback position, extrapolated from the last update while playing. */
  val positionMs: Long

  /** Duration, or -1 while unknown. */
  val durationMs: Long

  val isPlaying: Boolean

  val playbackSpeed: Double

  /** Video size in pixels, or 0 while unknown. */
  val videoWidth: Int

  val videoHeight: Int

  /** The video frame inside the player view, in pixels (empty while unknown). A copy. */
  val frameRect: Rect

  /** The video frame on screen, in pixels. A copy. */
  val frameRectOnScreen: Rect

  /** The player's Android view (the platform view), or null while it is not available. */
  val playerView: View?

  /**
   * A FrameLayout placed exactly over the video frame, above the video surface and below Flutter UI; created on first
   * use, null while no player view is available. Views added here must be removed by their owner;
   * prefer [addOverlay], which removes them when the session ends or the plugin unloads.
   */
  val overlayContainer: ViewGroup?

  /** Adds [view] over the video frame, filling it. Returns false if the session has no player view. */
  fun addOverlay(view: View): Boolean

  fun removeOverlay(view: View)

  /**
   * Copies the current video frame from the player's surface (no Flutter UI, no overlays). [width]/[height] in
   * pixels; 0 for the video's own size (one of them 0 keeps the aspect ratio). [callback] runs on a background thread
   * and owns the bitmap.
   */
  fun captureFrame(width: Int, height: Int, callback: FrameCallback)

  /**
   * Same as [captureFrame] into a file. [format]: `rgba` (raw RGBA8888, width * height * 4 bytes), `png` or `jpeg`.
   * Result `{ "path", "width", "height", "format", "positionMs" }`.
   */
  fun captureFrameToFile(width: Int, height: Int, format: String, callback: ResultCallback)

  fun addListener(listener: VideoSessionListener): Registration

  /** Playback control, carried out by the app's player (the `video.*` host functions); asynchronous. */
  fun play()

  fun pause()

  fun seekTo(positionMs: Long)

  fun setSpeed(speed: Double)

  fun setVolume(volume: Double)
}

/** Main thread. */
interface VideoSessionListener {
  fun onPosition(session: VideoSession, positionMs: Long, playing: Boolean) {}

  fun onFrameRectChanged(session: VideoSession, frameRect: Rect) {}

  fun onEnded(session: VideoSession) {}
}

fun interface FrameCallback {
  /** [frame] is null when the capture failed; [error] says why. */
  fun onFrame(frame: Bitmap?, error: String?)
}

/**
 * Optional interface for the plugin entry class: creates the native views the app attaches over a video
 * (`video.nativeOverlay.attach`, `videoPlayer.overlay` view items). Without it, [ImmichViewPlugin.createView] is used.
 * Either way `params` holds the overlay's own params plus `sessionId`, `assetId`, `viewId` and `overlayId`.
 */
interface ImmichVideoOverlayPlugin {
  fun createVideoOverlay(context: Context, viewType: String, params: String, session: VideoSession, host: PluginHost): View

  fun onVideoOverlayRemoved(viewType: String, view: View, session: VideoSession) {}
}
