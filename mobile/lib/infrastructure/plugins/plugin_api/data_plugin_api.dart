import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host_registry.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';

/// Plugin API of the **data** area: services, repositories, sync, upload, network, database and store
/// (`db.*`, `settings.*`, `assets.*`, `albums.*`, `tags.*`, `people.*`, `files.*`, `net.*`, `media.*`, `downloads.*`,
/// `sync.*`, `upload.*` host functions; the data hooks and events run through `PluginHooks`).
void registerDataPluginApi(PluginKernel kernel, Ref ref) {
  final services = DataPluginServices.build(ref, pluginDir: kernel.pluginDataDir);
  final docs = services.docs;
  for (final MapEntry(key: name, value: function) in services.functions.entries) {
    kernel.registerHost(
      name,
      (plugin, args) async {
        try {
          return await function(plugin, args);
        } on DataHostException catch (error) {
          throw HostFunctionException(error.status, error.message);
        }
      },
      doc: docs[name],
      area: 'data',
    );
  }

  // Plugins' database change subscriptions follow the installed plugins; downloads stop with their plugin.
  kernel.addListener(services.watcher.refresh);
  final unloaded = kernel.pluginUnloaded.listen((plugin) => unawaited(services.downloader.cancelAll(plugin)));
  ref.onDispose(() {
    kernel.removeListener(services.watcher.refresh);
    unawaited(unloaded.cancel());
    unawaited(services.dispose());
  });
}
