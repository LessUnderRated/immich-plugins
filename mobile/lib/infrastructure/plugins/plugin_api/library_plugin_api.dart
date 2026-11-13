import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_host_functions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/providers/map/map_plugin_layers.provider.dart';

/// Plugin API of the **library** area: albums, people, places, map, search, folders, partners, shared links and the
/// private gallery (UI-level host functions; map feature taps go back to the plugin that drew the feature).
void registerLibraryPluginApi(PluginKernel kernel, Ref ref) {
  final functions = LibraryHostFunctions(ref);
  for (final MapEntry(key: name, value: function) in functions.all.entries) {
    kernel.registerHost(name, function, doc: LibraryHostFunctions.docs[name], area: 'library');
  }

  // A tap on a plugin's map feature runs its action: a plugin method (`MapFeatureV1`) or a command.
  ref.read(mapPluginActionsProvider).handler = (plugin, action, data) async {
    final method = action['method'];
    final command = action['command'];
    if (method is String) {
      final params = action['params'];
      final response = await kernel.call(
        plugin,
        method,
        'MapFeatureV1',
        data,
        config: params is Map ? Map<String, dynamic>.from(params) : const {},
      );
      await kernel.perform(plugin, response);
    } else if (command is Map) {
      await kernel.command(plugin, Map<String, dynamic>.from(command));
    }
  };
}
