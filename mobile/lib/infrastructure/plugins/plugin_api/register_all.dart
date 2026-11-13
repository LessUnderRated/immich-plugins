import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data_plugin_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor_plugin_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library_plugin_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/native_plugin_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell_plugin_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline_plugin_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer_plugin_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:logging/logging.dart';

/// Registers every area's plugin API with [kernel], once, when `pluginKernelProvider` creates it. One failing area
/// is logged and does not keep the others (or the app) from starting.
void registerAllPluginApis(PluginKernel kernel, Ref ref) {
  final log = Logger('PluginApi');
  for (final (area, register) in <(String, void Function(PluginKernel, Ref))>[
    ('data', registerDataPluginApi),
    ('native', registerNativePluginApi),
    ('shell', registerShellPluginApi),
    ('timeline', registerTimelinePluginApi),
    ('library', registerLibraryPluginApi),
    ('viewer', registerViewerPluginApi),
    ('editor', registerEditorPluginApi),
  ]) {
    try {
      register(kernel, ref);
    } catch (error, stack) {
      log.severe('Unable to register the $area plugin API', error, stack);
    }
  }
}
