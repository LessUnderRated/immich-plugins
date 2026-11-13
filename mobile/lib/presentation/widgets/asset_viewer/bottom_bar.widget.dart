import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/builtin_rules.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_builtins.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/action_ids.dart';
import 'package:immich_mobile/presentation/actions/action_slots.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/edit_asset.action.dart';
import 'package:immich_mobile/presentation/actions/move_to_private.action.dart';
import 'package:immich_mobile/presentation/actions/restore.action.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/add_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/ocr_toggle_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_action_surface.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_carousel.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_slots.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/widgets/asset_viewer/video_controls.dart';
import 'package:immich_ui/immich_ui.dart';

// Resolved here rather than as an ActionColumnButton so a hidden restore takes no slot in the spaceEvenly row
// below. Each button keeps its action id (ViewerBuiltinIds.bottomBar) for plugin rules and `actions.list`.
List<Widget> _actionColumnButtons(BuildContext context, WidgetRef ref, List<ActionBuilder> actions) {
  final surface = ViewerActionSurfaceScope.maybeOf(context);
  return [
    for (final action in actions)
      if (_resolve(context, ref, action, surface) case final item?)
        _withId(
          action.id,
          ImmichColumnButton(
            icon: item.icon,
            label: item.label,
            onPressed: item.onAction,
            onLongPress: item.onSecondaryAction,
          ),
        ),
  ];
}

ActionItem? _resolve(BuildContext context, WidgetRef ref, ActionBuilder action, ViewerActionSurface? surface) {
  final item = action.resolve(context, ref);
  final id = action.id;
  if (id != null) {
    surface?.record(id, item);
  }
  return item;
}

Widget _withId(String? id, Widget child) => id == null ? child : BuiltinSlotItem(id: id, child: child);

class ViewerBottomBar extends ConsumerWidget {
  const ViewerBottomBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetViewerProvider.select((s) => s.currentAsset));
    if (asset == null) {
      return const SizedBox.shrink();
    }

    final isReadonlyModeEnabled = ref.watch(readonlyModeProvider);
    final showingDetails = ref.watch(assetViewerProvider.select((s) => s.showingDetails));
    final isInLockedView = ref.watch(inLockedViewProvider);
    final isInTrash = ref.watch(timelineServiceProvider).origin == TimelineOrigin.trash;

    final originalTheme = context.themeData;

    // Built-in ids: ViewerBuiltinIds.bottomBar. Plugin rules of `viewer.bottomBar` apply; its plugin actions join
    // the row. "Add to" is not an action builder: it keeps its place before "delete" unless rules hide or move it.
    const slots = [ViewerSlotIds.bottomBar];
    final rules = viewerSlotRules(ref, ViewerSlotIds.bottomBar);
    final builders = arrangeActions(ref, slots, [
      const RestoreAction(source: .viewer),
      const ShareAction(source: .viewer),
      if (!isInLockedView && !isInTrash) ...[
        const EditAssetAction(source: .viewer),
        const MoveToPrivateAction(source: .viewer),
      ],
      if (!isInLockedView) const DeleteAction(source: .viewer),
    ], source: .viewer);
    var actions = _actionColumnButtons(context, ref, builders);
    if (!isInLockedView && !isInTrash && asset.hasRemote && !rules.isHidden(ActionIds.addTo)) {
      final add = BuiltinSlotItem(
        id: ActionIds.addTo,
        child: ImmichColorOverride(color: null, child: AddActionButton(originalTheme: originalTheme)),
      );
      final deleteIndex = actions.indexWhere((widget) => slotItemId(widget) == ActionIds.delete);
      actions = [...actions]..insert(deleteIndex < 0 ? actions.length : deleteIndex, add);
      if (rules.order.isNotEmpty) {
        actions = reorderByIds(actions, slotItemId, rules.order);
      }
    }
    ViewerActionSurfaceScope.maybeOf(context)?.setBarOrder('bottomBar', actions);

    // Rows above the action row (ViewerBuiltinIds.bottomPanels).
    final panels = arrangeViewerSlot<Widget>(ref, ViewerSlotIds.bottomPanels, [
      if (asset.isImage) ViewerSlotItem('ocr', OcrToggleButton(asset: asset)),
      if (asset.isVideo) ViewerSlotItem('videoControls', VideoControls(videoPlayerName: asset.id)),
      const ViewerSlotItem('carousel', Padding(padding: EdgeInsets.symmetric(vertical: 6), child: ViewerCarousel())),
      if (!isReadonlyModeEnabled)
        ViewerSlotItem(
          'actions',
          ImmichColorOverride(
            color: Colors.white,
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: actions),
          ),
        ),
    ]);

    return AnimatedSwitcher(
      duration: Durations.short4,
      child: showingDetails
          ? const SizedBox.shrink()
          : Theme(
              data: context.themeData.copyWith(
                iconTheme: const IconThemeData(size: ImmichIconSize.md, color: Colors.white),
                textTheme: context.themeData.textTheme.copyWith(
                  labelLarge: context.themeData.textTheme.labelLarge?.copyWith(color: Colors.white),
                ),
              ),
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Colors.black45, Colors.black12, Colors.transparent],
                            stops: [0.0, 0.7, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(mainAxisSize: MainAxisSize.min, children: panels),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
