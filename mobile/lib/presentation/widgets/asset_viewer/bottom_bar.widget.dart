import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_builtins.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/edit_asset.action.dart';
import 'package:immich_mobile/presentation/actions/move_to_private.action.dart';
import 'package:immich_mobile/presentation/actions/restore.action.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/add_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/ocr_toggle_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_carousel.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/widgets/asset_viewer/video_controls.dart';
import 'package:immich_ui/immich_ui.dart';

// Resolved here rather than as an ActionColumnButton so a hidden restore
// takes no slot in the spaceEvenly row below. Each button keeps its catalog id (ViewerBuiltinIds.bottomBar).
List<ViewerSlotItem<Widget>> _actionColumnButtons(
  BuildContext context,
  WidgetRef ref,
  List<(String, ActionBuilder)> actions,
) => [
  for (final (id, action) in actions)
    if (action.create(context, ref) case final item?)
      ViewerSlotItem(
        id,
        ImmichColumnButton(
          icon: item.icon,
          label: item.label,
          onPressed: item.onAction,
          onLongPress: item.onSecondaryAction,
        ),
      ),
];

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

    final actions = arrangeViewerItems<Widget>(ViewerSlotIds.bottomBar, [
      ..._actionColumnButtons(context, ref, const [
        ('restore', RestoreAction(source: .viewer)),
        ('share', ShareAction(source: .viewer)),
      ]),

      if (!isInLockedView) ...[
        if (!isInTrash) ...[
          ..._actionColumnButtons(context, ref, const [
            ('edit', EditAssetAction(source: .viewer)),
            ('moveToPrivate', MoveToPrivateAction(source: .viewer)),
          ]),
          if (asset.hasRemote)
            ViewerSlotItem(
              'add',
              ImmichColorOverride(color: null, child: AddActionButton(originalTheme: originalTheme)),
            ),
        ],
        ..._actionColumnButtons(context, ref, const [('delete', DeleteAction(source: .viewer))]),
      ],
    ]);

    // Rows above the action row (ViewerBuiltinIds.bottomPanels).
    final panels = arrangeViewerItems<Widget>(ViewerSlotIds.bottomPanels, [
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
