import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/datetime_extensions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/presentation/actions/edit_asset.action.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/action_ids.dart';
import 'package:immich_mobile/presentation/actions/action_slots.dart';
import 'package:immich_mobile/presentation/actions/device_album.actions.dart';
import 'package:immich_mobile/presentation/actions/favorite.action.dart';
import 'package:immich_mobile/presentation/actions/plugin.action.dart';
import 'package:immich_mobile/presentation/plugins/plugin_ui.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/motion_photo_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_action_surface.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_censor.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_kebab_menu.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_slots.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/timezone.dart';
import 'package:immich_ui/immich_ui.dart';

class ViewerTopAppBar extends ConsumerWidget implements PreferredSizeWidget {
  static const double _fadeOverhang = 72;

  const ViewerTopAppBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetViewerProvider.select((s) => s.currentAsset));
    ref.listen(assetViewerProvider.select((s) => s.currentAsset), (_, next) {
      if (next is LocalAsset) {
        final engine = ref.read(deviceWorkflowEngineProvider);
        unawaited(engine.assetJson(next).then((json) => engine.emit('viewer.open', {'asset': json})));
      }
    });
    if (asset == null) {
      return const SizedBox.shrink();
    }

    final album = ref.watch(currentRemoteAlbumProvider);

    final isInLockedView = ref.watch(inLockedViewProvider);
    final isReadonlyModeEnabled = ref.watch(readonlyModeProvider);

    final showingDetails = ref.watch(assetViewerProvider.select((state) => state.showingDetails));

    if (album != null && album.isActivityEnabled && album.isShared && asset is RemoteAsset) {
      ref.watch(Store.activity.list(album.id, assetId: asset.id));
    }

    final showingControls = ref.watch(assetViewerProvider.select((s) => s.showingControls));
    final double opacity =
        ref.watch(assetViewerProvider.select((s) => s.backgroundOpacity)) * (showingControls ? 1 : 0);

    final originalTheme = context.themeData;

    // Built-in ids: ViewerBuiltinIds.topBar (action ids for the action buttons). Plugin rules hide, reorder and
    // rename them; plugin actions of `viewer.topBar` join them as icon buttons.
    final actions = arrangeActionWidgets(
      ref,
      const [ViewerSlotIds.topBar],
      [
        if (asset.isMotionPhoto)
          const BuiltinSlotItem(id: ActionIds.motionPhoto, child: MotionPhotoActionButton(iconOnly: true)),
        if (album != null && album.isActivityEnabled && album.isShared)
          BuiltinSlotItem(
            id: 'activity',
            child: IconButton(
              icon: const Icon(Icons.chat_outlined),
              onPressed: () {
                unawaited(
                  context.router.push(
                    ActivitiesRoute(
                      album: album,
                      assetId: asset is RemoteAsset ? asset.id : null,
                      assetName: asset.name,
                    ),
                  ),
                );
              },
            ),
          ),

        const ActionIconButton(action: FavoriteAction(source: .viewer)),
        const ActionIconButton(action: DeviceFavoriteAction(source: .viewer)),
        const ActionIconButton(action: RevertEditsAction(source: .viewer)),
        const ActionIconButton(action: PluginAction(source: .viewer)),
        const BuiltinSlotItem(id: 'censor', child: ViewerCensorButton()),
        PluginSlotButtons(slot: ViewerSlotIds.topBar, assets: [if (asset is LocalAsset) asset]),

        BuiltinSlotItem(
          id: 'menu',
          child: ImmichColorOverride(color: null, child: ViewerKebabMenu(originalTheme: originalTheme)),
        ),
      ],
      present: (action) => ActionIconButton(action: action),
      source: .viewer,
    );

    final lockedViewActions = arrangeActionWidgets(
      ref,
      const [ViewerSlotIds.topBar],
      [
        BuiltinSlotItem(
          id: 'menu',
          child: ViewerKebabMenu(originalTheme: originalTheme),
        ),
      ],
      present: (action) => ActionIconButton(action: action),
      source: .viewer,
    );
    ViewerActionSurfaceScope.maybeOf(context)?.setBarOrder('topBar', isInLockedView ? lockedViewActions : actions);

    return IgnorePointer(
      ignoring: opacity < 1.0,
      child: AnimatedOpacity(
        opacity: opacity,
        duration: Durations.short2,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: context.padding.top + preferredSize.height + _fadeOverhang,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: showingDetails
                        ? null
                        : const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xA6000000), Color(0x66000000), Color(0x1F000000), Colors.transparent],
                            stops: [0.0, 0.45, 0.75, 1.0],
                          ),
                  ),
                ),
              ),
            ),
            SafeArea(
              bottom: false,
              child: SizedBox(
                height: preferredSize.height,
                child: Theme(
                  data: context.themeData.copyWith(iconTheme: const IconThemeData(size: 22, color: Colors.white)),
                  child: NavigationToolbar(
                    centerMiddle: true,
                    leading: const _AppBarBackButton(),
                    middle: showingDetails
                        ? null
                        : ViewerSlotDecoration(
                            slot: ViewerSlotIds.title,
                            slotContext: () => PluginKernel.assetContext([asset]),
                            child: _AssetInfoTitle(asset: asset),
                          ),
                    trailing: !showingDetails && !isReadonlyModeEnabled
                        ? ImmichColorOverride(
                            color: Colors.white,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: isInLockedView ? lockedViewActions : actions,
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(60.0);
}

class _AppBarBackButton extends ConsumerWidget {
  const _AppBarBackButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showingDetails = ref.watch(assetViewerProvider.select((state) => state.showingDetails));
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: showingDetails ? context.colorScheme.surface : Colors.transparent,
        shape: const CircleBorder(),
        iconSize: 22,
        iconColor: showingDetails ? context.colorScheme.onSurface : Colors.white,
        padding: const EdgeInsets.all(10.0),
        elevation: showingDetails ? 4 : 0,
      ),
      onPressed: context.maybePop,
      child: const Icon(Icons.arrow_back_rounded),
    );
  }
}

class _AssetInfoTitle extends ConsumerWidget {
  static const _titleShadows = [Shadow(color: Color(0x99000000), blurRadius: 6)];

  final BaseAsset asset;

  const _AssetInfoTitle({required this.asset});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exifInfo = ref.watch(assetExifProvider(asset)).valueOrNull;
    final alwaysUse24HourFormat = MediaQuery.alwaysUse24HourFormatOf(context);

    final (dateTime, _) = resolveAssetDateTime(asset, exifInfo);

    final dateFormatted = dateTime.formatDate();
    final timeFormatted = dateTime.formatTime(alwaysUse24HourFormat: alwaysUse24HourFormat);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          dateFormatted,
          style: context.textTheme.labelLarge?.copyWith(color: Colors.white, shadows: _titleShadows),
        ),
        Text(
          timeFormatted,
          style: context.textTheme.labelMedium?.copyWith(color: Colors.white, shadows: _titleShadows),
        ),
      ],
    );
  }
}
