package app.alextran.immich.plugins

import app.alextran.immich.plugins.api.Registration
import java.util.concurrent.ConcurrentHashMap

/** Objects plugins share with each other in-process, by name `<plugin>/<name>`. */
internal object PluginServices {
  private class Entry(val owner: String, val service: Any)

  private val services = ConcurrentHashMap<String, Entry>()

  fun fullName(owner: String, name: String): String = if (name.startsWith("$owner/")) name else "$owner/$name"

  fun register(owner: String, name: String, service: Any): Registration {
    require(name.isNotBlank()) { "service name is required" }
    val key = fullName(owner, name)
    val entry = Entry(owner, service)
    check(services.putIfAbsent(key, entry) == null) { "Service $key already exists" }
    return PluginRuntime.scope(owner).track { services.remove(key, entry) }
  }

  fun get(name: String): Any? = services[name]?.service

  fun names(): List<String> = services.keys.sorted()
}
