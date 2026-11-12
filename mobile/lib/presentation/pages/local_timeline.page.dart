import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/plugins/plugin_ui.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/device_library_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/gallery_view/gallery_view_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/gallery_view.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';

@RoutePage()
class LocalTimelinePage extends ConsumerWidget {
  final LocalAlbum album;

  const LocalTimelinePage({super.key, required this.album});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(galleryViewSpecProvider(album.id)).valueOrNull;
    final hiddenIds = ref.watch(privateIdsProvider);
    return ProviderScope(
      key: ValueKey((view, hiddenIds.length, Object.hashAllUnordered(hiddenIds))),
      overrides: [
        timelineServiceProvider.overrideWith((ref) {
          final timelineService = ref
              .watch(timelineFactoryProvider)
              .localAlbum(albumId: album.id, view: view, hiddenIds: hiddenIds);
          ref.onDispose(timelineService.dispose);
          return timelineService;
        }),
      ],
      child: Timeline(
        appBar: MesmerizingSliverAppBar(
          title: album.name,
          actions: [
            const PluginSlotButtons(slot: 'album.appBar', color: Colors.white),
            GalleryViewButton(scope: album.id, color: Colors.white),
          ],
        ),
        groupBy: GroupAssetsBy.none,
        bottomSheet: DeviceLibraryBottomSheet(album: album),
        showStorageIndicator: false,
      ),
    );
  }
}
