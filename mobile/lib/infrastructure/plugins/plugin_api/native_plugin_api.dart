import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';

/// Plugin API of the **native** area (native Android plugin host: activity lifecycle, intents, permissions, notifications, background work, MediaStore writes, fast host calls).
///
/// Called once when the kernel is created (`registerAllPluginApis`). Register host functions with
/// `kernel.registerHost`, declare slots / hooks / events for `kernel.slots` / `kernel.hooks` / `kernel.events`, add
/// legacy slot aliases with `kernel.aliasSlot` and app toggles with `kernel.toggles.define`. Keep it cheap: no I/O here.
void registerNativePluginApi(PluginKernel kernel, Ref ref) {}
