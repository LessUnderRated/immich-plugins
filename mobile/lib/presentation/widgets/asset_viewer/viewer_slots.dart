import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/builtin_rules.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_builtins.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/providers/timeline/timeline_plugins.provider.dart';

/// Plugin hide / order / rename rules of a viewer slot. They come from the plugin bridge every bar and menu of the
/// app reads (bound by the kernel); reading them in `build` rebuilds the caller when plugins change.
BuiltinItemRules viewerSlotRules(WidgetRef ref, String slot) => ref.watch(timelinePluginBridgeProvider).rules([slot]);

/// [items] of viewer [slot] in display order after the plugins' rules (unchanged without plugins).
List<T> arrangeViewerSlot<T>(WidgetRef ref, String slot, List<ViewerSlotItem<T>> items) =>
    arrangeViewerItems(items, rules: viewerSlotRules(ref, slot));

/// Plugin content (`section`, `panel`, `view` contributions) of viewer [slot] for [assets], or null when no plugin
/// contributes to it. Rebuilds the caller when plugins change.
Widget? viewerSlotContent(
  WidgetRef ref,
  String slot, {
  List<BaseAsset> assets = const [],
  Map<String, dynamic> extra = const {},
}) {
  final bridge = ref.watch(timelinePluginBridgeProvider);
  if (!bridge.hasContent(slot)) {
    return null;
  }
  return bridge.content(slot, {...PluginKernel.assetContext(assets), ...extra});
}
