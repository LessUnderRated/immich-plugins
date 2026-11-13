import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';
import 'package:immich_mobile/infrastructure/plugins/censor_styles.dart';
import 'package:immich_mobile/infrastructure/plugins/device_plugin_store.dart';
import 'package:immich_mobile/infrastructure/plugins/device_workflow_engine.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_runtime.dart';
import 'package:immich_mobile/infrastructure/repositories/device_edit.repository.dart';
import 'package:immich_mobile/providers/app_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/device_tag.provider.dart';
import 'package:immich_mobile/providers/infrastructure/media_writer.provider.dart';

final Provider<DeviceEditRepository> deviceEditRepositoryProvider = Provider<DeviceEditRepository>((ref) {
  ref.keepAlive();
  return DeviceEditRepository(
    privateFiles: ref.read(privateFilesRepositoryProvider),
    censorEffects: (style, options, source, size, width, height) =>
        ref.read(censorStylesProvider).render(style, options, source, size, width, height),
  );
});

final Provider<DeviceWorkflowEngine> deviceWorkflowEngineProvider = Provider<DeviceWorkflowEngine>((ref) {
  ref.keepAlive();
  final engine = DeviceWorkflowEngine(
    ref.watch(driftProvider),
    DevicePluginStore(),
    PluginRuntime(),
    ref.watch(deviceEditRepositoryProvider),
    ref.watch(appAlbumRepositoryProvider),
    mediaWriter: ref.watch(mediaWriterProvider),
    tagRepository: ref.watch(deviceTagRepositoryProvider),
  );
  ref.onDispose(() => unawaited(engine.dispose()));
  return engine;
});

final Provider<CensorStyles> censorStylesProvider = Provider<CensorStyles>(
  (ref) => CensorStyles(ref.watch(deviceWorkflowEngineProvider)),
);

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

final censorStyleOptionsProvider = FutureProvider<List<CensorStyleOption>>((ref) {
  ref.watch(_engineChangesProvider);
  return ref.watch(censorStylesProvider).list();
});

final assetActionMethodsProvider = FutureProvider<List<(DevicePlugin, DevicePluginMethod)>>((ref) {
  ref.watch(_engineChangesProvider);
  return ref.watch(deviceWorkflowEngineProvider).assetActionMethods();
});

final pluginFilesRootProvider = FutureProvider<String>((ref) => ref.watch(deviceWorkflowEngineProvider).pluginsRoot());
