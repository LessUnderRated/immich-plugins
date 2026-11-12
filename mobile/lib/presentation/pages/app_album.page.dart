import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/presentation/plugins/plugin_ui.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/device_library_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/gallery_view/gallery_view_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/app_album.provider.dart';
import 'package:immich_mobile/providers/gallery_view.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';

@RoutePage()
class AppAlbumPage extends ConsumerWidget {
  final String albumId;

  const AppAlbumPage({super.key, required this.albumId});

  Future<void> _rename(BuildContext context, WidgetRef ref, String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename album'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      await ref.read(appAlbumRepositoryProvider).rename(albumId, name);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "$name"?'),
        content: const Text('Only the album is deleted. Its photos stay on your phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(appAlbumRepositoryProvider).delete(albumId);
      if (context.mounted) {
        await context.maybePop();
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final album = ref.watch(appAlbumProvider(albumId)).valueOrNull;
    final view = ref.watch(galleryViewSpecProvider(albumId)).valueOrNull;
    final hiddenIds = ref.watch(privateIdsProvider);
    if (album == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return ProviderScope(
      key: ValueKey((Object.hashAll(album.assetIds), view, Object.hashAllUnordered(hiddenIds))),
      overrides: [
        timelineServiceProvider.overrideWith((ref) {
          final timelineService = ref
              .watch(timelineFactoryProvider)
              .appAlbum(album.assetIds, view: view, hiddenIds: hiddenIds);
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
            PopupMenuButton<String>(
              iconColor: Colors.white,
              onSelected: (value) =>
                  value == 'rename' ? _rename(context, ref, album.name) : _delete(context, ref, album.name),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'delete', child: Text('Delete album')),
              ],
            ),
          ],
        ),
        groupBy: GroupAssetsBy.none,
        bottomSheet: DeviceLibraryBottomSheet(appAlbumId: album.id),
      ),
    );
  }
}
