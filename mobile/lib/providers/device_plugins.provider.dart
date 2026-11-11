import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';
import 'package:immich_mobile/infrastructure/plugins/device_plugin_store.dart';
import 'package:immich_mobile/infrastructure/plugins/device_workflow_engine.dart';
import 'package:immich_mobile/infrastructure/plugins/wasm_plugin_runtime.dart';
import 'package:immich_mobile/infrastructure/repositories/device_edit.repository.dart';
import 'package:immich_mobile/providers/app_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';

final deviceWorkflowEngineProvider = Provider<DeviceWorkflowEngine>((ref) {
  ref.keepAlive();
  return DeviceWorkflowEngine(
    ref.watch(driftProvider),
    DevicePluginStore(),
    WasmPluginRuntime(),
    const DeviceEditRepository(),
    ref.watch(appAlbumRepositoryProvider),
  );
});

final _engineChangesProvider = StreamProvider<void>((ref) => ref.watch(deviceWorkflowEngineProvider).changes);

final devicePluginsProvider = FutureProvider<List<DevicePlugin>>((ref) async {
  ref.watch(_engineChangesProvider);
  final engine = ref.watch(deviceWorkflowEngineProvider);
  await engine.ensureReady();
  return engine.plugins();
});

final deviceWorkflowsProvider = FutureProvider<List<DeviceWorkflow>>((ref) async {
  ref.watch(_engineChangesProvider);
  return ref.watch(deviceWorkflowEngineProvider).workflows();
});
