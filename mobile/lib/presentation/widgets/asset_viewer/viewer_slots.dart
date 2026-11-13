import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/builtin_rules.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_builtins.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/presentation/plugins/plugin_slot.dart';
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

/// [child] with the plugin decorations (`badge`, `wrap`, `replace`) of [slot]; [child] itself without them.
class ViewerSlotDecoration extends ConsumerWidget {
  final String slot;
  final Map<String, dynamic> Function() slotContext;
  final Widget child;

  const ViewerSlotDecoration({super.key, required this.slot, required this.slotContext, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bridge = ref.watch(timelinePluginBridgeProvider);
    return bridge.hasDecorations(slot) ? bridge.decorate(slot, slotContext(), child) : child;
  }
}

/// The plugin content of [slot] (nothing without plugins).
class ViewerSlotContentView extends ConsumerWidget {
  final String slot;
  final List<BaseAsset> assets;
  final Map<String, dynamic> extra;

  const ViewerSlotContentView({super.key, required this.slot, this.assets = const [], this.extra = const {}});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      viewerSlotContent(ref, slot, assets: assets, extra: extra) ?? const SizedBox.shrink();
}

/// An empty state (or any default block) plugins can replace: `replace` / `wrap` items of [slot] change [fallback],
/// and `section` content of [slot] takes its place.
class SlotContentOr extends ConsumerWidget {
  final String slot;
  final Widget fallback;
  final Map<String, dynamic> slotContext;

  const SlotContentOr({super.key, required this.slot, required this.fallback, this.slotContext = const {}});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content = viewerSlotContent(ref, slot, extra: slotContext);
    return PluginReplaceable(slot: slot, slotContext: slotContext, child: content ?? fallback);
  }
}
