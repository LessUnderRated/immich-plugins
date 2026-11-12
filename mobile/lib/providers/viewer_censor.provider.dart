import 'dart:convert';
import 'dart:ui' as ui;

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/plugins/viewer_filter.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';

final viewerFilterProvider = Provider<ViewerFilter>(
  (ref) => ViewerFilter(
    ref.watch(deviceWorkflowEngineProvider),
    ref.watch(deviceEditRepositoryProvider),
    ref.watch(censorStylesProvider),
  ),
);

final viewerFilterAvailableProvider = FutureProvider<bool>((ref) async {
  await ref.watch(devicePluginsProvider.future);
  return ref.watch(viewerFilterProvider).isAvailable();
});

class ViewerCensorEnabled extends Notifier<bool> {
  @override
  bool build() => Store.tryGet(StoreKey.viewerCensor) ?? true;

  Future<void> toggle() async {
    state = !state;
    await Store.put(StoreKey.viewerCensor, state);
  }
}

final viewerCensorEnabledProvider = NotifierProvider<ViewerCensorEnabled, bool>(ViewerCensorEnabled.new);

class ViewerCensorConfig extends Notifier<Map<String, dynamic>> {
  @override
  Map<String, dynamic> build() {
    final stored = Store.tryGet(StoreKey.viewerCensorConfig);
    if (stored == null || stored.isEmpty) {
      return const {};
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(stored) as Map);
    } catch (_) {
      return const {};
    }
  }

  Future<void> set(Map<String, dynamic> config) async {
    state = config;
    await Store.put(StoreKey.viewerCensorConfig, jsonEncode(config));
  }
}

final viewerCensorConfigProvider = NotifierProvider<ViewerCensorConfig, Map<String, dynamic>>(ViewerCensorConfig.new);

final viewerCensorActiveProvider = Provider<bool>(
  (ref) => ref.watch(viewerCensorEnabledProvider) && (ref.watch(viewerFilterAvailableProvider).valueOrNull ?? false),
);

final censoredPhotoProvider = FutureProvider.autoDispose.family<ui.Image?, String>((ref, assetId) async {
  final config = ref.watch(viewerCensorConfigProvider);
  final image = await ref.watch(viewerFilterProvider).censorPhoto(assetId, config);
  ref.onDispose(() => image?.dispose());
  return image;
});
