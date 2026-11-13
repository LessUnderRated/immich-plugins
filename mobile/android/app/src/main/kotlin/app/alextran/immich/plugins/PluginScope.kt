package app.alextran.immich.plugins

import app.alextran.immich.plugins.api.Registration
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

/** Everything one plugin registered natively; cleared when the plugin is unloaded. */
internal class PluginScope(val plugin: String) {
  private val registrations = CopyOnWriteArrayList<Tracked>()

  private inner class Tracked(private val onRemove: () -> Unit) : Registration {
    private val removed = AtomicBoolean(false)

    override fun remove() {
      if (removed.compareAndSet(false, true)) {
        registrations.remove(this)
        PluginCrashGuard.run(plugin, "remove registration") { onRemove() }
      }
    }
  }

  /** Returns a registration that runs [onRemove] once, when the plugin removes it or is unloaded. */
  fun track(onRemove: () -> Unit): Registration = Tracked(onRemove).also { registrations.add(it) }

  fun clear() {
    registrations.toList().forEach { it.remove() }
  }
}
