import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_json.dart';
import 'package:immich_mobile/infrastructure/repositories/app_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/duplicate_finder.repository.dart';
import 'package:immich_mobile/pages/common/large_leading_tile.dart';
import 'package:immich_mobile/presentation/actions/device_album.actions.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_slots.dart';
import 'package:immich_mobile/presentation/widgets/downloads_rule_dialog.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/local_album_thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/library/library_plugins.widget.dart';
import 'package:immich_mobile/presentation/widgets/sliver_app_bar/app_menu.widget.dart';
import 'package:immich_mobile/providers/app_album.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/routing/router.dart';

const _page = LibraryPages.localAlbums;

@RoutePage()
class LocalAlbumsPage extends ConsumerWidget {
  const LocalAlbumsPage({super.key});

  Future<void> _findDuplicates(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final finder = DuplicateFinderRepository(ref.read(driftProvider));
    final groups = await finder.findCopies();
    final copies = groups.fold<int>(0, (sum, group) => sum + group.copyIds.length);
    if (!context.mounted) {
      return;
    }
    if (copies == 0) {
      messenger.showSnackBar(const SnackBar(content: Text('No duplicates found')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $copies duplicate${copies == 1 ? '' : 's'}?'),
        content: Text(
          'Found ${groups.length} photo${groups.length == 1 ? '' : 's'} saved more than once (same name, date and size). '
          'The original of each is kept and the extra copies are deleted. Android will ask you to confirm.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    final deleted = await finder.deleteCopies(groups);
    await ref.read(backgroundSyncProvider).syncLocal();
    messenger.showSnackBar(SnackBar(content: Text('Removed $deleted duplicate${deleted == 1 ? '' : 's'}')));
  }

  Future<void> _newAlbum(BuildContext context, WidgetRef ref) async {
    final name = await askName(context, title: 'New album');
    if (name == null) {
      return;
    }
    final album = await ref.read(appAlbumRepositoryProvider).create(name);
    if (context.mounted) {
      unawaited(context.pushRoute(AppAlbumRoute(albumId: album.id)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            floating: true,
            snap: true,
            centerTitle: true,
            title: Text(context.t.albums),
            actions: LibraryPluginHooks.arrange(LibrarySlots.appBarActions(_page), [
              (
                id: 'downloads',
                item: IconButton(
                  tooltip: 'Downloads',
                  icon: const Icon(Icons.download_done_outlined),
                  onPressed: () => libraryTap(context, _page, 'downloads', () => showDownloadsRuleDialog(context)),
                ),
              ),
              (
                id: 'findDuplicates',
                item: IconButton(
                  tooltip: 'Find duplicates',
                  icon: const Icon(Icons.copy_all_outlined),
                  onPressed: () => libraryTap(context, _page, 'findDuplicates', () => _findDuplicates(context, ref)),
                ),
              ),
              (
                id: 'newAlbum',
                item: IconButton(
                  tooltip: 'New album',
                  icon: const Icon(Icons.add),
                  onPressed: () => libraryTap(context, _page, 'newAlbum', () => _newAlbum(context, ref)),
                ),
              ),
              // Settings gear and the app menu (Trash, Plugins, Locked folder, Logs; slots `app.appBar.actions`,
              // `app.menu`)
              (id: 'appMenu', item: const AppBarMenuActions()),
            ]),
          ),
          ...LibraryPluginHooks.arrange(LibrarySlots.localAlbumsSections, [
            (id: 'appAlbums', item: const _AppAlbumList()),
            (
              id: 'deviceTitle',
              item: SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                  child: Text(context.t.on_this_device, style: context.textTheme.titleSmall),
                ),
              ),
            ),
            (id: 'deviceAlbums', item: const _AlbumList()),
          ]),
        ],
      ),
    );
  }
}

class _AppAlbumList extends ConsumerWidget {
  const _AppAlbumList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(appAlbumsProvider).valueOrNull ?? const <AppAlbum>[];
    if (albums.isEmpty) {
      return SliverToBoxAdapter(
        child: SlotContentOr(
          slot: LibrarySlots.localAlbumsAppAlbumsEmpty,
          fallback: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: Text(
              'Your albums appear here. Select photos and tap "Add to album" to make one.',
              style: context.textTheme.bodySmall,
            ),
          ),
        ),
      );
    }
    final sorted = [...albums]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return LibraryQueryBuilder<AppAlbum>(
      hook: LibraryHooks.appAlbumsQuery,
      items: sorted,
      id: (album) => album.id,
      toJson: LibraryJson.appAlbum,
      placeholder: (_) => const SliverToBoxAdapter(child: SizedBox.shrink()),
      builder: (context, sorted) => SliverPadding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
        sliver: SliverList.builder(
          itemCount: sorted.length,
          itemBuilder: (context, index) {
            final album = sorted[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: LibraryTileDecoration(
                key: ValueKey(album.id),
                slot: LibrarySlots.localAlbumsAppAlbum,
                slotContext: () => {'album': LibraryJson.appAlbum(album)},
                child: LargeLeadingTile(
                  leadingPadding: const EdgeInsets.only(right: 16),
                  leading: SizedBox(width: 80, height: 80, child: _AppAlbumCover(album: album)),
                  title: Text(album.name, style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    context.t.items_count(count: album.assetIds.length),
                    style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
                  ),
                  onTap: () => libraryTap(
                    context,
                    _page,
                    'openAppAlbum',
                    () => context.pushRoute(AppAlbumRoute(albumId: album.id)),
                    args: () => {'album': LibraryJson.appAlbum(album)},
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AppAlbumCover extends ConsumerWidget {
  final AppAlbum album;

  const _AppAlbumCover({required this.album});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverId = album.assetIds.lastOrNull;
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: const Icon(Icons.photo_album_outlined),
    );
    if (coverId == null) {
      return placeholder;
    }
    final db = ref.watch(driftProvider);
    return FutureBuilder(
      future: (db.localAssetEntity.select()..where((row) => row.id.equals(coverId))).getSingleOrNull(),
      builder: (context, snapshot) {
        final row = snapshot.data;
        if (row == null) {
          return placeholder;
        }
        return ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          child: Thumbnail.fromAsset(asset: row.toDto(), size: const Size(160, 160)),
        );
      },
    );
  }
}

class _AlbumList extends ConsumerWidget {
  const _AlbumList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(localAlbumProvider);

    return albums.when(
      loading: () => const SliverToBoxAdapter(
        child: Center(
          child: Padding(padding: EdgeInsets.all(20.0), child: CircularProgressIndicator()),
        ),
      ),
      error: (error, stack) => SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Text(
              'Error loading albums: $error, stack: $stack',
              style: TextStyle(color: context.colorScheme.error),
            ),
          ),
        ),
      ),
      data: (albums) {
        if (albums.isEmpty) {
          return SliverToBoxAdapter(
            child: SlotContentOr(
              slot: LibrarySlots.localAlbumsDeviceAlbumsEmpty,
              fallback: Center(
                child: Padding(padding: const EdgeInsets.all(20.0), child: Text(context.t.no_albums_yet)),
              ),
            ),
          );
        }

        return LibraryQueryBuilder<LocalAlbum>(
          hook: LibraryHooks.deviceAlbumsQuery,
          items: albums,
          id: (album) => album.id,
          toJson: LibraryJson.deviceAlbum,
          placeholder: (_) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          builder: (context, albums) => SliverPadding(
            padding: const EdgeInsets.all(18.0),
            sliver: SliverList.builder(
              itemBuilder: (_, index) {
                final album = albums[index];

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: LibraryTileDecoration(
                    key: ValueKey(album.id),
                    slot: LibrarySlots.localAlbumsDeviceAlbum,
                    slotContext: () => {'album': LibraryJson.deviceAlbum(album)},
                    child: LargeLeadingTile(
                      leadingPadding: const EdgeInsets.only(right: 16),
                      leading: SizedBox(width: 80, height: 80, child: LocalAlbumThumbnail(albumId: album.id)),
                      title: Text(
                        album.name,
                        style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        context.t.items_count(count: album.assetCount),
                        style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
                      ),
                      onTap: () => libraryTap(
                        context,
                        _page,
                        'openDeviceAlbum',
                        () => context.pushRoute(LocalTimelineRoute(album: album)),
                        args: () => {'album': LibraryJson.deviceAlbum(album)},
                      ),
                    ),
                  ),
                );
              },
              itemCount: albums.length,
            ),
          ),
        );
      },
    );
  }
}
