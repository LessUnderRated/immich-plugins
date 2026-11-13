import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';

/// Plugin API of the **shell** area (app shell: settings (plugin settings pages), backup / sync UI, auth, theme and string overrides, logs, share intent, profile, bottom navigation tabs).
///
/// Called once when the kernel is created (`registerAllPluginApis`). Register host functions with
/// `kernel.registerHost`, declare slots / hooks / events for `kernel.slots` / `kernel.hooks` / `kernel.events`, add
/// legacy slot aliases with `kernel.aliasSlot` and app toggles with `kernel.toggles.define`. Keep it cheap: no I/O here.
void registerShellPluginApi(PluginKernel kernel, Ref ref) {}
