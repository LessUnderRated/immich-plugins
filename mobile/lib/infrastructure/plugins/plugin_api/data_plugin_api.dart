import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';

/// Plugin API of the **data** area (data: services, repositories, sync, upload, network, database, store (`asset.*`, `album.*`, `settings.*`, `db.*`, `files.*`, `net.*` hooks, events and host functions)).
///
/// Called once when the kernel is created (`registerAllPluginApis`). Register host functions with
/// `kernel.registerHost`, declare slots / hooks / events for `kernel.slots` / `kernel.hooks` / `kernel.events`, add
/// legacy slot aliases with `kernel.aliasSlot` and app toggles with `kernel.toggles.define`. Keep it cheap: no I/O here.
void registerDataPluginApi(PluginKernel kernel, Ref ref) {}
