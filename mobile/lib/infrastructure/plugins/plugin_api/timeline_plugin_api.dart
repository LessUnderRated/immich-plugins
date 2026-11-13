import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';

/// Plugin API of the **timeline** area (timeline, selection, actions and tabs: tile badges / wrap / replace, headers, scrubber, group headers, selection bar, empty state, query hooks, `action.<id>` hooks).
///
/// Called once when the kernel is created (`registerAllPluginApis`). Register host functions with
/// `kernel.registerHost`, declare slots / hooks / events for `kernel.slots` / `kernel.hooks` / `kernel.events`, add
/// legacy slot aliases with `kernel.aliasSlot` and app toggles with `kernel.toggles.define`. Keep it cheap: no I/O here.
void registerTimelinePluginApi(PluginKernel kernel, Ref ref) {}
