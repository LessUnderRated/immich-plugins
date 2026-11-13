import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/extensions/asyncvalue_extensions.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_json.dart';
import 'package:immich_mobile/presentation/widgets/images/local_album_thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/library/library_plugins.widget.dart';
import 'package:immich_mobile/presentation/widgets/people/partner_user_avatar.widget.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/widgets/common/immich_sliver_app_bar.dart';
import 'package:immich_mobile/widgets/map/map_thumbnail.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

const _page = LibraryPages.library;

/// Opens a library entry through hook `action.library.<id>`.
void _open(
  BuildContext context,
  String id,
  Future<void> Function() original, {
  Map<String, dynamic> Function()? args,
}) => libraryTap(context, _page, id, original, args: args);

@RoutePage()
class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const ImmichSliverAppBar(snap: false, floating: false, pinned: true, showUploadButton: false),
          ...LibraryPluginHooks.arrange(LibrarySlots.librarySections, const [
            (id: 'actions', item: _ActionButtonGrid()),
            (id: 'collections', item: _CollectionCards()),
            (id: 'quickAccess', item: _QuickAccessButtonList()),
          ]),
        ],
      ),
    );
  }
}

class _ActionButtonGrid extends ConsumerWidget {
  const _ActionButtonGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTrashEnable = ref.watch(serverInfoProvider.select((state) => state.serverFeatures.trash));
    final buttons = LibraryPluginHooks.arrange(LibrarySlots.libraryActions, [
      (
        id: 'favorites',
        item: _ActionButton(
          icon: Icons.favorite_outline_rounded,
          onTap: () => _open(context, 'favorites', () => context.pushRoute(const FavoriteRoute())),
          label: context.t.favorites,
        ),
      ),
      (
        id: 'archived',
        item: _ActionButton(
          icon: Icons.archive_outlined,
          onTap: () => _open(context, 'archived', () => context.pushRoute(const ArchiveRoute())),
          label: context.t.archived,
        ),
      ),
      (
        id: 'sharedLinks',
        item: _ActionButton(
          icon: Icons.link_outlined,
          onTap: () => _open(context, 'sharedLinks', () => context.pushRoute(const SharedLinkRoute())),
          label: context.t.shared_links,
        ),
      ),
      if (isTrashEnable)
        (
          id: 'trash',
          item: _ActionButton(
            icon: Icons.delete_outline_rounded,
            onTap: () => _open(context, 'trash', () => context.pushRoute(const TrashRoute())),
            label: context.t.trash,
          ),
        ),
    ]);

    // Two buttons per row
    final rows = <Widget>[];
    for (var i = 0; i < buttons.length; i += 2) {
      if (rows.isNotEmpty) {
        rows.add(const SizedBox(height: 8));
      }
      rows.add(
        Row(
          children: [
            buttons[i],
            if (i + 1 < buttons.length) ...[const SizedBox(width: 8), buttons[i + 1]],
          ],
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.only(left: 16, top: 16, right: 16, bottom: 12),
      sliver: SliverToBoxAdapter(child: Column(children: rows)),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.onTap, required this.label});

  final IconData icon;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: FilledButton.icon(
        onPressed: onTap,
        label: Padding(
          padding: const EdgeInsets.only(left: 4.0),
          child: Text(label, style: TextStyle(color: context.colorScheme.onSurface, fontSize: 15)),
        ),
        style: FilledButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          backgroundColor: context.colorScheme.surfaceContainerLow,
          alignment: Alignment.centerLeft,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(Radius.circular(25)),
            side: BorderSide(color: context.colorScheme.onSurface.withAlpha(10), width: 1),
          ),
        ),
        icon: Icon(icon, color: context.primaryColor),
      ),
    );
  }
}

class _CollectionCards extends StatelessWidget {
  const _CollectionCards();

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverToBoxAdapter(
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: LibraryPluginHooks.arrange(LibrarySlots.libraryCollections, const [
            (id: 'people', item: _PeopleCollectionCard()),
            (id: 'places', item: _PlacesCollectionCard()),
            (id: 'onThisDevice', item: _LocalAlbumsCollectionCard()),
            (id: 'memories', item: _MemoriesCollectionCard()),
          ]),
        ),
      ),
    );
  }
}

class _PeopleCollectionCard extends ConsumerWidget {
  const _PeopleCollectionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(Store.people.all());

    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = constraints.maxWidth > 600;
        final widthFactor = isTablet ? 0.25 : 0.5;
        final size = context.width * widthFactor - 20.0;

        return GestureDetector(
          onTap: () => _open(context, 'people', () => context.pushRoute(const PeopleCollectionRoute())),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: size,
                width: size,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(20)),
                  gradient: LinearGradient(
                    colors: [context.colorScheme.primary.withAlpha(30), context.colorScheme.primary.withAlpha(25)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: people.widgetWhen(
                  onLoading: () => const Center(child: CircularProgressIndicator()),
                  onData: (people) {
                    return GridView.count(
                      crossAxisCount: 2,
                      padding: const EdgeInsets.all(12),
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      physics: const NeverScrollableScrollPhysics(),
                      children: people.take(4).map((person) {
                        return CircleAvatar(
                          backgroundImage: RemoteImageProvider(
                            url: getFaceThumbnailUrl(person.id, updatedAt: person.updatedAt),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  context.t.people,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PlacesCollectionCard extends StatelessWidget {
  const _PlacesCollectionCard();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = constraints.maxWidth > 600;
        final widthFactor = isTablet ? 0.25 : 0.5;
        final size = context.width * widthFactor - 20.0;

        return GestureDetector(
          onTap: () => _open(context, 'places', () => context.pushRoute(PlaceRoute(currentLocation: null))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: size,
                width: size,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.circular(20)),
                    color: context.colorScheme.secondaryContainer.withAlpha(100),
                  ),
                  child: IgnorePointer(
                    child: MapThumbnail(
                      zoom: 8,
                      centre: const LatLng(21.44950, -157.91959),
                      showAttribution: false,
                      themeMode: context.isDarkTheme ? ThemeMode.dark : ThemeMode.light,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  context.t.places,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LocalAlbumsCollectionCard extends ConsumerWidget {
  const _LocalAlbumsCollectionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(localAlbumProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = constraints.maxWidth > 600;
        final widthFactor = isTablet ? 0.25 : 0.5;
        final size = context.width * widthFactor - 20.0;

        return GestureDetector(
          onTap: () => _open(context, 'onThisDevice', () => context.pushRoute(const LocalAlbumsRoute())),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: size,
                width: size,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.circular(20)),
                    gradient: LinearGradient(
                      colors: [context.colorScheme.primary.withAlpha(30), context.colorScheme.primary.withAlpha(25)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: GridView.count(
                    crossAxisCount: 2,
                    padding: const EdgeInsets.all(12),
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    physics: const NeverScrollableScrollPhysics(),
                    children: albums.when(
                      data: (data) {
                        return data.take(4).map((album) {
                          return LocalAlbumThumbnail(albumId: album.id);
                        }).toList();
                      },
                      error: (error, _) {
                        return [Center(child: Text(context.t.error_saving_image(error: error.toString())))];
                      },
                      loading: () {
                        return [const Center(child: CircularProgressIndicator())];
                      },
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  context.t.on_this_device,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MemoriesCollectionCard extends ConsumerWidget {
  const _MemoriesCollectionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memories = ref.watch(allMemoriesProvider(false));

    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = constraints.maxWidth > 600;
        final widthFactor = isTablet ? 0.25 : 0.5;
        final size = context.width * widthFactor - 20.0;

        return GestureDetector(
          onTap: () => _open(context, 'memories', () => context.pushRoute(const MemoryListRoute())),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: size,
                width: size,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(20)),
                  gradient: LinearGradient(
                    colors: [context.colorScheme.primary.withAlpha(30), context.colorScheme.primary.withAlpha(25)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: memories.widgetWhen(
                  onLoading: () => const Center(child: CircularProgressIndicator()),
                  onData: (memories) {
                    return GridView.count(
                      crossAxisCount: 2,
                      padding: const EdgeInsets.all(12),
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      physics: const NeverScrollableScrollPhysics(),
                      children: memories.take(4).map((memory) {
                        return ClipRRect(
                          borderRadius: const BorderRadius.all(Radius.circular(10)),
                          child: Thumbnail.remote(
                            remoteId: memory.assets[0].id,
                            thumbhash: memory.assets[0].thumbHash ?? "",
                            fit: BoxFit.cover,
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  context.t.memories,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

@visibleForTesting
final sharedWithPartnerProvider = StreamProvider.autoDispose<Iterable<Partner>>((ref) {
  final currentUser = ref.watch(currentUserProvider);
  if (currentUser == null) {
    // TODO: Refactor with a route guard to avoid this check in every provider
    return const .empty();
  }

  return ref.watch(partnerServiceProvider).search(currentUser.id, .sharedWith);
});

class _QuickAccessItem {
  final Widget leading;
  final String title;
  final VoidCallback onTap;
  final EdgeInsetsGeometry? contentPadding;

  const _QuickAccessItem({required this.leading, required this.title, required this.onTap, this.contentPadding});
}

class _QuickAccessButtonList extends ConsumerWidget {
  const _QuickAccessButtonList();

  static const _tileRadius = 20.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final partnerSharedWithAsync = ref.watch(sharedWithPartnerProvider);
    final partners = partnerSharedWithAsync.valueOrNull ?? [];

    final items = LibraryPluginHooks.arrange(LibrarySlots.libraryQuickAccess, [
      (
        id: 'folders',
        item: _QuickAccessItem(
          leading: const Icon(Icons.folder_outlined, size: 26),
          title: context.t.folders,
          onTap: () => _open(context, 'folders', () => context.pushRoute(FolderRoute())),
        ),
      ),
      (
        id: 'lockedFolder',
        item: _QuickAccessItem(
          leading: const Icon(Icons.lock_outline_rounded, size: 26),
          title: context.t.locked_folder,
          onTap: () => _open(context, 'lockedFolder', () => context.pushRoute(const LockedFolderRoute())),
        ),
      ),
      (
        id: 'partners',
        item: _QuickAccessItem(
          leading: const Icon(Icons.group_outlined, size: 26),
          title: context.t.partners,
          onTap: () => _open(context, 'partners', () => context.pushRoute(const PartnerRoute())),
        ),
      ),
      for (final partner in partners)
        (
          id: 'partner:${partner.id}',
          item: _QuickAccessItem(
            contentPadding: const EdgeInsets.only(left: 12.0, right: 18.0),
            leading: PartnerUserAvatar(userId: partner.id, name: partner.name),
            title: context.t.partner_list_user_photos(user: partner.name),
            onTap: () => _open(
              context,
              'partner',
              () => context.pushRoute(PartnerDetailRoute(partner: partner)),
              args: () => {'partner': LibraryJson.partner(partner)},
            ),
          ),
        ),
    ]);

    return SliverPadding(
      padding: const EdgeInsets.only(left: 16, top: 12, right: 16, bottom: 32),
      sliver: SliverToBoxAdapter(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: context.colorScheme.onSurface.withAlpha(10), width: 1),
            borderRadius: const BorderRadius.all(Radius.circular(_tileRadius)),
            gradient: LinearGradient(
              colors: [
                context.colorScheme.primary.withAlpha(10),
                context.colorScheme.primary.withAlpha(15),
                context.colorScheme.primary.withAlpha(20),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final isFirst = index == 0;
              final isLast = index == items.length - 1;
              return ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(isFirst ? _tileRadius : 0),
                    topRight: Radius.circular(isFirst ? _tileRadius : 0),
                    bottomLeft: Radius.circular(isLast ? _tileRadius : 0),
                    bottomRight: Radius.circular(isLast ? _tileRadius : 0),
                  ),
                ),
                contentPadding: item.contentPadding,
                leading: item.leading,
                title: Text(item.title, style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500)),
                onTap: item.onTap,
              );
            },
          ),
        ),
      ),
    );
  }
}
