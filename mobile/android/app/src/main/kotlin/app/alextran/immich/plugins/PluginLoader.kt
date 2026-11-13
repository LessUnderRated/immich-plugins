package app.alextran.immich.plugins

import android.content.Context
import android.os.Build
import app.alextran.immich.plugins.api.ImmichPlugin
import dalvik.system.DexClassLoader
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/** Instantiates dex plugins. Shared by the app's plugin host, startup loads, background work and notification actions. */
internal object PluginLoader {
  class Loaded(val plugin: ImmichPlugin, val loader: ClassLoader)

  private val libraryGeneration = AtomicInteger()

  fun instantiate(context: Context, key: String, source: File, entry: String): Loaded {
    require(source.isFile) { "Plugin $key: ${source.path} does not exist" }
    val directory = File(context.codeCacheDir, "dex-plugins").apply { mkdirs() }
    val name = "$key-${source.lastModified()}-${source.length()}.dex"
    val target = File(directory, name)
    if (!target.exists() || target.length() != source.length()) {
      val stale = Regex("^${Regex.escape(key)}-\\d+-\\d+\\.dex$")
      directory.listFiles { file -> file.isFile && stale.matches(file.name) }?.forEach { old ->
        old.setWritable(true)
        old.delete()
      }
      source.copyTo(target, overwrite = true)
    }
    // Android 14 refuses writable dex files.
    target.setReadOnly()

    val optimized = File(directory, "oat").apply { mkdirs() }
    val loader = DexClassLoader(
      target.path,
      optimized.path,
      copyNativeLibraries(context, key, source.parentFile ?: directory),
      PluginLoader::class.java.classLoader,
    )
    val instance = loader.loadClass(entry).getDeclaredConstructor().newInstance()
    val plugin = instance as? ImmichPlugin
      ?: throw IllegalStateException("$entry does not implement ${ImmichPlugin::class.java.name}")
    return Loaded(plugin, loader)
  }

  /**
   * Copies `files/lib/<abi>/` of the plugin to a fresh folder per load: a native library can belong to one class
   * loader only, so a reloaded plugin needs its own copy.
   */
  private fun copyNativeLibraries(context: Context, key: String, pluginRoot: File): String? {
    val libraries = File(pluginRoot, "files/lib")
    val abi = Build.SUPPORTED_ABIS.firstOrNull { File(libraries, it).isDirectory } ?: return null
    val parent = File(context.codeCacheDir, "dex-plugins")
    val prefix = "$key-libs"
    parent.listFiles { file -> file.isDirectory && (file.name == prefix || file.name.startsWith("$prefix-")) }
      ?.forEach { old ->
        old.walkBottomUp().forEach { it.setWritable(true) }
        old.deleteRecursively()
      }
    val target = File(parent, "$prefix-${libraryGeneration.incrementAndGet()}-${System.currentTimeMillis()}")
    target.mkdirs()
    File(libraries, abi).listFiles { file -> file.name.endsWith(".so") }?.forEach { library ->
      val copy = File(target, library.name)
      library.copyTo(copy, overwrite = true)
      copy.setReadOnly()
    }
    return target.path
  }
}

/**
 * Plugins the app has loaded, persisted so that background work, notification actions and startup loads can load a
 * plugin natively while the Flutter side is not running.
 */
internal object PluginRegistryStore {
  class Record(val name: String, val dexPath: String, val entry: String, val enabled: Boolean, val startup: Boolean)

  private const val PREFS = "immich_native_plugins"

  private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  private fun decode(name: String, text: String?): Record? {
    val json = PluginJson.parse(text) as? JSONObject ?: return null
    val dexPath = json.optString("dexPath")
    val entry = json.optString("entry")
    if (dexPath.isEmpty() || entry.isEmpty()) {
      return null
    }
    return Record(name, dexPath, entry, json.optBoolean("enabled", true), json.optBoolean("startup", false))
  }

  private fun write(context: Context, record: Record) {
    val json = JSONObject()
      .put("dexPath", record.dexPath)
      .put("entry", record.entry)
      .put("enabled", record.enabled)
      .put("startup", record.startup)
    prefs(context).edit().putString(record.name, json.toString()).apply()
  }

  @Synchronized
  fun get(context: Context, name: String): Record? = decode(name, prefs(context).getString(name, null))

  @Synchronized
  fun all(context: Context): List<Record> =
    prefs(context).all.mapNotNull { (name, value) -> decode(name, value as? String) }

  @Synchronized
  fun put(context: Context, name: String, dexPath: String, entry: String) {
    val startup = get(context, name)?.startup ?: false
    write(context, Record(name, dexPath, entry, enabled = true, startup = startup))
  }

  @Synchronized
  fun setEnabled(context: Context, name: String, enabled: Boolean) {
    val record = get(context, name) ?: return
    write(context, Record(name, record.dexPath, record.entry, enabled, record.startup))
  }

  @Synchronized
  fun setStartup(context: Context, name: String, startup: Boolean) {
    val record = get(context, name) ?: return
    write(context, Record(name, record.dexPath, record.entry, record.enabled, startup))
  }

  @Synchronized
  fun remove(context: Context, name: String) {
    prefs(context).edit().remove(name).apply()
  }
}
