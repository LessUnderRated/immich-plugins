import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_builtins.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/setting.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/utils/action_button.utils.dart';
import 'package:immich_ui/immich_ui.dart';

class ViewerKebabMenu extends ConsumerWidget {
  const ViewerKebabMenu({super.key, this.originalTheme});

  final ThemeData? originalTheme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetViewerProvider.select((s) => s.currentAsset));
    if (asset == null) {
      return const SizedBox.shrink();
    }

    final user = ref.watch(currentUserProvider);
    final isOwner = asset is RemoteAsset && asset.ownerId == user?.id;
    final isCasting = ref.watch(castProvider.select((c) => c.isCasting));
    final timelineOrigin = ref.watch(timelineServiceProvider).origin;
    final isInLockedView = ref.watch(inLockedViewProvider);
    final currentAlbum = ref.watch(currentRemoteAlbumProvider);
    final isArchived = asset is RemoteAsset && asset.visibility == AssetVisibility.archive;
    final advancedTroubleshooting = ref.watch(settingsProvider.notifier).get(.advancedTroubleshooting);

    final actionContext = ActionButtonContext(
      asset: asset,
      isOwner: isOwner,
      isArchived: isArchived,
      isStacked: asset is RemoteAsset && asset.stackId != null,
      isInLockedView: isInLockedView,
      currentAlbum: currentAlbum,
      advancedTroubleshooting: advancedTroubleshooting,
      source: ActionSource.viewer,
      isCasting: isCasting,
      timelineOrigin: timelineOrigin,
    );

    final menuChildren = _menuChildren(actionContext, context);

    return ImmichMenu(
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(context.themeData.scaffoldBackgroundColor),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.grey),
        elevation: const WidgetStatePropertyAll(4),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      ),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 150),
          child: Theme(
            data: originalTheme ?? context.themeData,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: menuChildren,
            ),
          ),
        ),
      ],
      builder: (context, controller, child) {
        return IconButton(
          icon: const Icon(Icons.more_vert_rounded),
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        );
      },
    );
  }

  /// `ActionButtonBuilder.buildViewerKebabMenu` with stable ids (the button type names, ViewerBuiltinIds.menu) so
  /// plugins can hide and reorder the entries. Dividers separate the groups of neighbouring entries.
  static List<Widget> _menuChildren(ActionButtonContext actionContext, BuildContext buildContext) {
    final visible = [
      for (final type in ActionButtonBuilder.defaultViewerKebabMenuOrder)
        if (!ActionButtonBuilder.defaultViewerBottomBarButtons.contains(type) && type.shouldShow(actionContext))
          ViewerSlotItem(type.name, type),
    ];
    final types = arrangeViewerItems(ViewerSlotIds.menu, visible);

    final result = <Widget>[];
    int? lastGroup;
    for (final type in types) {
      if (lastGroup != null && type.kebabMenuGroup != lastGroup) {
        result.add(const Divider(height: 1));
      }
      result.add(type.buildButton(actionContext, buildContext, false, true));
      lastGroup = type.kebabMenuGroup;
    }
    return result;
  }
}
