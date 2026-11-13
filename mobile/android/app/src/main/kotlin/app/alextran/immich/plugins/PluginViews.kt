package app.alextran.immich.plugins

import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import app.alextran.immich.plugins.api.PluginTheme
import app.alextran.immich.plugins.api.Registration
import app.alextran.immich.plugins.api.ThemeListener
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Plugin platform views: the app theme for native code, content-height reporting for inline views, and the
 * crash-isolating [PluginViewContainer] DexPluginHost wraps every plugin view in.
 */
internal object PluginViews {
  private class ThemeEntry(val plugin: String, val listener: ThemeListener)

  private val themeListeners = CopyOnWriteArrayList<ThemeEntry>()
  private val views = ConcurrentHashMap<Int, PluginViewContainer>()

  @Volatile
  private var current: PluginTheme? = null

  val theme: PluginTheme
    get() = current ?: systemTheme()

  /** Called by Dart (`setTheme`) whenever the app theme changes. */
  fun setTheme(json: String) {
    val theme = parseTheme(PluginJson.obj(json))
    current = theme
    PluginRuntime.runOnMain {
      for (entry in themeListeners) {
        PluginCrashGuard.run(entry.plugin, "theme listener") { entry.listener.onThemeChanged(theme) }
      }
    }
  }

  fun addThemeListener(plugin: String, listener: ThemeListener): Registration {
    val entry = ThemeEntry(plugin, listener)
    themeListeners.add(entry)
    return PluginRuntime.scope(plugin).track { themeListeners.remove(entry) }
  }

  private fun systemTheme(): PluginTheme {
    val dark = PluginRuntime.isInitialized &&
      (PluginRuntime.context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    return PluginTheme(dark, emptyMap(), null, 1.0, JSONObject().put("dark", dark).put("colors", JSONObject()).toString())
  }

  private fun parseTheme(json: JSONObject): PluginTheme {
    val colors = mutableMapOf<String, Int>()
    json.optJSONObject("colors")?.let { map ->
      val keys = map.keys()
      while (keys.hasNext()) {
        val key = keys.next()
        when (val value = map.opt(key)) {
          is Number -> colors[key] = value.toLong().toInt()
          is String -> try {
            colors[key] = Color.parseColor(value)
          } catch (_: IllegalArgumentException) {
            // Ignore colors the platform cannot parse.
          }
        }
      }
    }
    return PluginTheme(
      isDark = json.optBoolean("dark", false),
      colors = colors,
      fontFamily = if (json.has("fontFamily") && !json.isNull("fontFamily")) json.optString("fontFamily") else null,
      textScale = json.optDouble("textScale", 1.0),
      json = json.toString(),
    )
  }

  // ---- view registry --------------------------------------------------------------------------------------------

  /**
   * Wraps the view a plugin created for platform view [viewId] (DexPluginHost.create). The container isolates the
   * plugin's measure, layout, draw and touch failures and identifies the view for content-height reports.
   */
  fun wrap(context: Context, plugin: String, viewType: String, viewId: Int, view: View): PluginViewContainer {
    val container = PluginViewContainer(context, plugin, viewType, viewId)
    (view.parent as? ViewGroup)?.removeView(view)
    container.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    views[viewId] = container
    return container
  }

  /** DexPluginHost: platform view [viewId] was disposed. */
  fun unregister(viewId: Int) {
    views.remove(viewId)?.disposed = true
  }

  fun container(viewId: Int): PluginViewContainer? = views[viewId]

  fun containerOf(view: View): PluginViewContainer? {
    var current: View? = view
    while (current != null) {
      if (current is PluginViewContainer) {
        return current
      }
      current = current.parent as? View
    }
    return null
  }

  fun viewId(view: View): Int = containerOf(view)?.viewId ?: -1

  fun setContentHeight(view: View, heightPx: Int) {
    val container = containerOf(view) ?: return
    val density = view.resources.displayMetrics.density
    PluginNativeBridge.contentHeight(container.viewId, heightPx / density.toDouble())
  }

  fun autoContentHeight(plugin: String, view: View): Registration {
    var last = -1
    val measure = Runnable {
      val container = containerOf(view) ?: return@Runnable
      val child = container.getChildAt(0) ?: return@Runnable
      if (container.width <= 0) {
        return@Runnable
      }
      val width = View.MeasureSpec.makeMeasureSpec(container.width, View.MeasureSpec.EXACTLY)
      child.measure(width, View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
      val height = child.measuredHeight
      child.measure(width, View.MeasureSpec.makeMeasureSpec(container.height, View.MeasureSpec.EXACTLY))
      if (height != last) {
        last = height
        setContentHeight(view, height)
      }
    }
    val listener = View.OnLayoutChangeListener { target, _, _, _, _, _, _, _, _ ->
      target.post(PluginCrashGuard.wrap(plugin, "content height", measure))
    }
    PluginRuntime.runOnMain {
      view.addOnLayoutChangeListener(listener)
      view.post(PluginCrashGuard.wrap(plugin, "content height", measure))
    }
    return PluginRuntime.scope(plugin).track {
      PluginRuntime.runOnMain { view.removeOnLayoutChangeListener(listener) }
    }
  }
}

/**
 * Holds one plugin view. A failure while measuring, laying out, drawing or handling input is reported and the plugin
 * view is replaced by a short message instead of crashing the app.
 */
class PluginViewContainer internal constructor(
  context: Context,
  val plugin: String,
  val viewType: String,
  val viewId: Int,
) : FrameLayout(context) {
  @Volatile
  internal var disposed = false

  /** False: touches pass through to the views below (non-interactive overlays). */
  var touchable = true

  private var failed = false

  private fun fail(where: String, error: Throwable) {
    PluginCrashGuard.report(plugin, "view $viewType $where", error)
    if (failed) {
      return
    }
    failed = true
    post {
      removeAllViews()
      addView(
        TextView(context).apply {
          text = "Plugin view failed: ${error.message ?: error.javaClass.simpleName}"
          setTextColor(Color.WHITE)
          gravity = Gravity.CENTER
        },
        LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
      )
    }
  }

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    try {
      super.onMeasure(widthMeasureSpec, heightMeasureSpec)
    } catch (error: Throwable) {
      setMeasuredDimension(
        getDefaultSize(suggestedMinimumWidth, widthMeasureSpec),
        getDefaultSize(suggestedMinimumHeight, heightMeasureSpec),
      )
      fail("measure", error)
    }
  }

  override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
    try {
      super.onLayout(changed, left, top, right, bottom)
    } catch (error: Throwable) {
      fail("layout", error)
    }
  }

  override fun dispatchDraw(canvas: Canvas) {
    val saveCount = canvas.saveCount
    try {
      super.dispatchDraw(canvas)
    } catch (error: Throwable) {
      canvas.restoreToCount(saveCount)
      fail("draw", error)
    }
  }

  override fun dispatchTouchEvent(event: MotionEvent): Boolean = try {
    touchable && super.dispatchTouchEvent(event)
  } catch (error: Throwable) {
    fail("touch", error)
    true
  }

  override fun dispatchKeyEvent(event: KeyEvent): Boolean = try {
    super.dispatchKeyEvent(event)
  } catch (error: Throwable) {
    fail("key", error)
    true
  }
}
