import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_host_functions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';

/// Plugin API of the **timeline** area: `timeline.*`, `selection.*`, `actions.list/run` and `tabs.*` host functions.
/// Slots, rules, decorations and tabs reach the timeline through `KernelTimelinePluginBridge`.
void registerTimelinePluginApi(PluginKernel kernel, Ref ref) {
  for (final MapEntry(key: name, value: function) in TimelineHostFunctions.all.entries) {
    kernel.registerHost(
      name,
      (plugin, args) async {
        try {
          return await function(plugin, args);
        } on TimelineHostError catch (error) {
          throw HostFunctionException(400, error.message);
        }
      },
      doc: TimelineHostFunctions.docs[name],
      area: 'timeline',
    );
  }
}
