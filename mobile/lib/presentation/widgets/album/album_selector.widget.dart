import 'dart:async';
import 'dart:math';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_json.dart';
import 'package:immich_mobile/models/albums/album_search.model.dart';
import 'package:immich_mobile/presentation/widgets/album/album_tile.dart';
import 'package:immich_mobile/presentation/widgets/album/new_album_name_modal.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/library/library_plugins.widget.dart';
import 'package:immich_mobile/providers/album/album_sort_by_options.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/album_filter.utils.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_mobile/widgets/common/search_field.dart';
import 'package:sliver_tools/sliver_tools.dart';

typedef AlbumSelectorCallback = void Function(RemoteAlbum album);

/// Plugin page key of the album selector's built-in actions (`action.albumSelector.<item>`).
const _selectorPage = 'albumSelector';

class AlbumSelector extends ConsumerStatefulWidget {
  final AlbumSelectorCallback onAlbumSelected;
  final Function? onKeyboardExpanded;

  /// Where the selector is shown, for plugins (`scope` in slot contexts and hook arguments): `albums` on the album
  /// list page, `picker` in "add to album" sheets.
  final String scope;

  const AlbumSelector({super.key, required this.onAlbumSelected, this.onKeyboardExpanded, this.scope = 'picker'});

  @override
  ConsumerState<AlbumSelector> createState() => _AlbumSelectorState();
}

class _AlbumSelectorState extends ConsumerState<AlbumSelector> {
  bool isGrid = false;
  final searchController = TextEditingController();
  final menuController = MenuController();
  final searchFocusNode = FocusNode();
  List<RemoteAlbum> sortedAlbums = [];
  List<RemoteAlbum> shownAlbums = [];

  AlbumFilter filter = const AlbumFilter(query: "", mode: QuickFilterMode.all);
  AlbumSort sort = const AlbumSort(mode: AlbumSortMode.lastModified, isReverse: true);

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final albumConfig = ref.read(appConfigProvider).album;

      setState(() {
        sort = AlbumSort(mode: albumConfig.sortMode, isReverse: albumConfig.isReverse);
        isGrid = albumConfig.isGrid;
      });

      unawaited(ref.read(remoteAlbumProvider.notifier).refresh());
    });

    searchController.addListener(() {
      onSearch(searchController.text, filter.mode);
    });

    searchFocusNode.addListener(() {
      if (searchFocusNode.hasFocus) {
        widget.onKeyboardExpanded?.call();
      }
    });
  }

  void onSearch(String searchTerm, QuickFilterMode filterMode) {
    final userId = ref.read(currentUserProvider)?.id;
    filter = filter.copyWith(query: searchTerm, userId: userId, mode: filterMode);

    unawaited(filterAlbums());
  }

  Map<String, dynamic> _hookArgs() => {'scope': widget.scope};

  void toggleViewMode() => libraryTap(context, _selectorPage, 'viewMode', () {
    setState(() {
      isGrid = !isGrid;
    });
    unawaited(ref.read(settingsProvider).write(.albumIsGrid, isGrid));
    LibraryPluginHooks.emit(LibraryEvents.albumsViewModeChanged, () => {..._hookArgs(), 'isGrid': isGrid});
  }, args: () => {..._hookArgs(), 'isGrid': !isGrid});

  void changeFilter(QuickFilterMode mode) {
    setState(() {
      filter = filter.copyWith(mode: mode);
    });

    unawaited(filterAlbums());
    LibraryPluginHooks.emit(
      LibraryEvents.albumsFilterChanged,
      () => {..._hookArgs(), 'mode': mode.name, 'query': filter.query},
    );
  }

  Future<void> changeSort(AlbumSort sort) async {
    await runLibraryAction<void>(context, _selectorPage, sort.mode.name, () async {
      setState(() {
        this.sort = sort;
      });

      final metadata = ref.read(settingsProvider);
      await metadata.write(.albumSortMode, sort.mode);
      await metadata.write(.albumIsReverse, sort.isReverse);

      await sortAlbums();
      LibraryPluginHooks.emit(
        LibraryEvents.albumsSortChanged,
        () => {..._hookArgs(), 'mode': sort.mode.name, 'reverse': sort.isReverse},
      );
    }, args: () => {..._hookArgs(), 'mode': sort.mode.name, 'reverse': sort.isReverse});
  }

  /// Opens [album] through hook `action.albumSelector.open`.
  void openAlbum(RemoteAlbum album) => libraryTap(
    context,
    _selectorPage,
    'open',
    () => widget.onAlbumSelected(album),
    args: () => {..._hookArgs(), 'album': LibraryJson.remoteAlbum(album)},
  );

  /// Deletes [album] through hook `action.albumSelector.delete`; true when it was deleted.
  Future<bool> deleteAlbum(RemoteAlbum album) async {
    var deleted = false;
    await runLibraryAction<void>(context, _selectorPage, 'delete', () async {
      await ref.read(remoteAlbumProvider.notifier).deleteAlbum(album.id);
      deleted = true;
    }, args: () => {..._hookArgs(), 'album': LibraryJson.remoteAlbum(album)});
    return deleted;
  }

  /// The albums to show after query hook `albums.query`.
  Future<List<RemoteAlbum>> _query(List<RemoteAlbum> albums) async => LibraryPluginHooks.query<RemoteAlbum>(
    LibraryHooks.albumsQuery,
    albums,
    id: (album) => album.id,
    toJson: LibraryJson.remoteAlbum,
    args: () => {
      ..._hookArgs(),
      'filter': {'query': filter.query, 'mode': filter.mode.name},
      'sort': {'mode': sort.mode.name, 'reverse': sort.isReverse},
    },
  );

  void clearSearch() {
    setState(() {
      filter = filter.copyWith(mode: QuickFilterMode.all, query: null);
      searchController.clear();
    });

    unawaited(filterAlbums());
  }

  Future<void> sortAlbums() async {
    final sorted = await ref
        .read(remoteAlbumProvider.notifier)
        .sortAlbums(ref.read(remoteAlbumProvider).albums, sort.mode, isReverse: sort.isReverse);

    if (!mounted) {
      return;
    }

    setState(() {
      sortedAlbums = sorted;
    });

    // we need to re-filter the albums after sorting
    // so shownAlbums gets updated
    unawaited(filterAlbums());
  }

  Future<void> filterAlbums() async {
    final hooked = LibraryPluginHooks.has(LibraryHooks.albumsQuery);
    if (filter.query == null) {
      final albums = hooked ? await _query(sortedAlbums) : sortedAlbums;
      if (!mounted) {
        return;
      }

      setState(() {
        shownAlbums = albums;
      });

      return;
    }

    final filteredAlbums = ref
        .read(remoteAlbumProvider.notifier)
        .searchAlbums(sortedAlbums, filter.query!, filter.userId, filter.mode);
    final albums = hooked ? await _query(filteredAlbums) : filteredAlbums;

    if (!mounted) {
      return;
    }

    setState(() {
      shownAlbums = albums;
    });
  }

  @override
  void dispose() {
    searchController.dispose();
    searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userId = ref.watch(currentUserProvider.select((user) => user?.id));

    // refilter and sort when albums change
    ref.listen(remoteAlbumProvider.select((state) => state.albums), (_, _) async {
      await sortAlbums();
    });

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        menuController.close();
      },
      child: MultiSliver(
        children: LibraryPluginHooks.arrange(LibrarySlots.albumSelectorSections, [
          (
            id: 'search',
            item: _SearchBar(
              searchController: searchController,
              searchFocusNode: searchFocusNode,
              onSearch: onSearch,
              filterMode: filter.mode,
              onClearSearch: clearSearch,
            ),
          ),
          (
            id: 'filters',
            item: _QuickFilterButtonRow(
              filterMode: filter.mode,
              onChangeFilter: (mode) => libraryTap(
                context,
                _selectorPage,
                mode.name,
                () => changeFilter(mode),
                args: () => {..._hookArgs(), 'mode': mode.name},
              ),
              onSearch: onSearch,
              searchController: searchController,
            ),
          ),
          (
            id: 'toolbar',
            item: _QuickSortAndViewMode(
              isGrid: isGrid,
              onToggleViewMode: toggleViewMode,
              onSortChanged: changeSort,
              controller: menuController,
              currentSortMode: sort.mode,
              currentIsReverse: sort.isReverse,
            ),
          ),
          (
            id: 'list',
            item: isGrid
                ? _AlbumGrid(albums: shownAlbums, userId: userId, onAlbumSelected: openAlbum)
                : _AlbumList(albums: shownAlbums, userId: userId, onAlbumSelected: openAlbum, onDelete: deleteAlbum),
          ),
        ]),
      ),
    );
  }
}

class _SortButton extends ConsumerStatefulWidget {
  const _SortButton(
    this.onSortChanged, {
    required this.initialSortMode,
    required this.initialIsReverse,
    this.controller,
  });

  final Future<void> Function(AlbumSort) onSortChanged;
  final MenuController? controller;
  final AlbumSortMode initialSortMode;
  final bool initialIsReverse;

  @override
  ConsumerState<_SortButton> createState() => _SortButtonState();
}

class _SortButtonState extends ConsumerState<_SortButton> {
  late AlbumSortMode albumSortOption;
  late bool albumSortIsReverse;
  bool isSorting = false;

  @override
  void initState() {
    super.initState();
    albumSortOption = widget.initialSortMode;
    albumSortIsReverse = widget.initialIsReverse;
  }

  @override
  void didUpdateWidget(_SortButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSortMode != widget.initialSortMode || oldWidget.initialIsReverse != widget.initialIsReverse) {
      setState(() {
        albumSortOption = widget.initialSortMode;
        albumSortIsReverse = widget.initialIsReverse;
      });
    }
  }

  Future<void> onMenuTapped(AlbumSortMode sortMode) async {
    final selected = albumSortOption == sortMode;
    // Switch direction
    if (selected) {
      setState(() {
        albumSortIsReverse = !albumSortIsReverse;
        isSorting = true;
      });
    } else {
      setState(() {
        albumSortOption = sortMode;
        isSorting = true;
        // reset sort order to default state when switching option
        albumSortIsReverse = false;
      });
    }

    await widget.onSortChanged.call(AlbumSort(mode: albumSortOption, isReverse: albumSortIsReverse));

    setState(() {
      isSorting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final effectiveOrder = albumSortOption.effectiveOrder(albumSortIsReverse);
    return MenuAnchor(
      controller: widget.controller,
      style: MenuStyle(
        elevation: const WidgetStatePropertyAll(1),
        shape: WidgetStateProperty.all(
          const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
      ),
      consumeOutsideTap: true,
      menuChildren: LibraryPluginHooks.arrange(LibrarySlots.albumSelectorSort, [
        for (final sortMode in AlbumSortMode.values)
          (
            id: sortMode.name,
            item: MenuItemButton(
              leadingIcon: albumSortOption == sortMode
                  ? effectiveOrder == SortOrder.desc
                        ? Icon(
                            Icons.keyboard_arrow_down,
                            color: albumSortOption == sortMode
                                ? context.colorScheme.onPrimary
                                : context.colorScheme.onSurface,
                          )
                        : Icon(
                            Icons.keyboard_arrow_up_rounded,
                            color: albumSortOption == sortMode
                                ? context.colorScheme.onPrimary
                                : context.colorScheme.onSurface,
                          )
                  : const Icon(Icons.abc, color: Colors.transparent),
              onPressed: () => onMenuTapped(sortMode),
              style: ButtonStyle(
                padding: WidgetStateProperty.all(const EdgeInsets.fromLTRB(12, 12, 24, 12)),
                backgroundColor: WidgetStateProperty.all(
                  albumSortOption == sortMode ? context.colorScheme.primary : Colors.transparent,
                ),
                shape: WidgetStateProperty.all(
                  const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                ),
              ),
              child: Text(
                sortMode.label(context.t),
                style: context.textTheme.labelLarge?.copyWith(
                  color: albumSortOption == sortMode
                      ? context.colorScheme.onPrimary
                      : context.colorScheme.onSurface.withAlpha(185),
                ),
              ),
            ),
          ),
      ]),
      builder: (context, controller, child) {
        return GestureDetector(
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: effectiveOrder == SortOrder.desc
                    ? Icon(Icons.keyboard_arrow_down, color: context.colorScheme.onSurface)
                    : Icon(Icons.keyboard_arrow_up_rounded, color: context.colorScheme.onSurface),
              ),
              Text(
                albumSortOption.label(context.t),
                style: context.textTheme.labelLarge?.copyWith(color: context.colorScheme.onSurface.withAlpha(225)),
              ),
              isSorting
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.colorScheme.onSurface.withAlpha(225),
                      ),
                    )
                  : const SizedBox.shrink(),
            ],
          ),
        );
      },
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.searchController,
    required this.searchFocusNode,
    required this.onSearch,
    required this.filterMode,
    required this.onClearSearch,
  });

  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final void Function(String, QuickFilterMode) onSearch;
  final QuickFilterMode filterMode;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      sliver: SliverToBoxAdapter(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: context.colorScheme.onSurface.withAlpha(0), width: 0),
            borderRadius: const BorderRadius.all(Radius.circular(24)),
            gradient: LinearGradient(
              colors: [
                context.colorScheme.primary.withValues(alpha: 0.075),
                context.colorScheme.primary.withValues(alpha: 0.09),
                context.colorScheme.primary.withValues(alpha: 0.075),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              transform: const GradientRotation(0.5 * pi),
            ),
          ),
          child: SearchField(
            autofocus: false,
            contentPadding: const EdgeInsets.all(16),
            hintText: context.t.search_albums,
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: searchController.text.isNotEmpty
                ? IconButton(icon: const Icon(Icons.clear_rounded), onPressed: onClearSearch)
                : null,
            controller: searchController,
            onChanged: (_) => onSearch(searchController.text, filterMode),
            focusNode: searchFocusNode,
            onTapOutside: (_) => searchFocusNode.unfocus(),
          ),
        ),
      ),
    );
  }
}

class _QuickFilterButtonRow extends StatelessWidget {
  const _QuickFilterButtonRow({
    required this.filterMode,
    required this.onChangeFilter,
    required this.onSearch,
    required this.searchController,
  });

  final QuickFilterMode filterMode;
  final void Function(QuickFilterMode) onChangeFilter;
  final void Function(String, QuickFilterMode) onSearch;
  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverToBoxAdapter(
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: LibraryPluginHooks.arrange(LibrarySlots.albumSelectorFilters, [
            (
              id: QuickFilterMode.all.name,
              item: _QuickFilterButton(
                label: context.t.all,
                isSelected: filterMode == QuickFilterMode.all,
                onTap: () {
                  onChangeFilter(QuickFilterMode.all);
                  onSearch(searchController.text, QuickFilterMode.all);
                },
              ),
            ),
            (
              id: QuickFilterMode.sharedWithMe.name,
              item: _QuickFilterButton(
                label: context.t.shared_with_me,
                isSelected: filterMode == QuickFilterMode.sharedWithMe,
                onTap: () {
                  onChangeFilter(QuickFilterMode.sharedWithMe);
                  onSearch(searchController.text, QuickFilterMode.sharedWithMe);
                },
              ),
            ),
            (
              id: QuickFilterMode.myAlbums.name,
              item: _QuickFilterButton(
                label: context.t.my_albums,
                isSelected: filterMode == QuickFilterMode.myAlbums,
                onTap: () {
                  onChangeFilter(QuickFilterMode.myAlbums);
                  onSearch(searchController.text, QuickFilterMode.myAlbums);
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _QuickFilterButton extends StatelessWidget {
  const _QuickFilterButton({required this.isSelected, required this.onTap, required this.label});

  final bool isSelected;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.all(isSelected ? context.colorScheme.primary : Colors.transparent),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            side: BorderSide(color: context.colorScheme.onSurface.withAlpha(25), width: 1),
          ),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isSelected ? context.colorScheme.onPrimary : context.colorScheme.onSurface,
          fontSize: 14,
        ),
      ),
    );
  }
}

class _QuickSortAndViewMode extends StatelessWidget {
  const _QuickSortAndViewMode({
    required this.isGrid,
    required this.onToggleViewMode,
    required this.onSortChanged,
    required this.currentSortMode,
    required this.currentIsReverse,
    this.controller,
  });

  final bool isGrid;
  final VoidCallback onToggleViewMode;
  final MenuController? controller;
  final Future<void> Function(AlbumSort) onSortChanged;
  final AlbumSortMode currentSortMode;
  final bool currentIsReverse;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverToBoxAdapter(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: LibraryPluginHooks.arrange(LibrarySlots.albumSelectorToolbar, [
            (
              id: 'sort',
              item: _SortButton(
                onSortChanged,
                controller: controller,
                initialSortMode: currentSortMode,
                initialIsReverse: currentIsReverse,
              ),
            ),
            (
              id: 'viewMode',
              item: IconButton(
                icon: Icon(
                  isGrid ? Icons.view_list_outlined : Icons.grid_view_outlined,
                  size: 24,
                  color: context.colorScheme.onSurface,
                ),
                onPressed: onToggleViewMode,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _AlbumList extends ConsumerWidget {
  const _AlbumList({required this.albums, required this.userId, required this.onAlbumSelected, required this.onDelete});

  final List<RemoteAlbum> albums;
  final String? userId;
  final AlbumSelectorCallback onAlbumSelected;
  final Future<bool> Function(RemoteAlbum album) onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (albums.isEmpty) {
      return SliverToBoxAdapter(
        child: Center(
          child: Padding(padding: const EdgeInsets.all(20.0), child: Text(context.t.album_search_not_found)),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.only(left: 16.0, right: 16, bottom: 64),
      sliver: SliverList.builder(
        itemBuilder: (_, index) {
          final album = albums[index];
          final isOwner = album.ownerId == userId;

          if (isOwner) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Dismissible(
                key: ValueKey(album.id),
                background: Container(
                  color: context.colorScheme.error,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  child: Icon(Icons.delete, color: context.colorScheme.onError),
                ),
                direction: DismissDirection.endToStart,
                confirmDismiss: (direction) async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => ConfirmDialog(
                      onOk: () => true,
                      title: context.t.delete_album,
                      content: context.t.album_delete_confirmation(album: album.name),
                      ok: context.t.delete,
                    ),
                  );
                  // With a plugin on `action.albumSelector.delete`, delete before dismissing so a cancel keeps the tile
                  if (confirmed != true || !LibraryPluginHooks.hasAction(_selectorPage, 'delete')) {
                    return confirmed;
                  }
                  return onDelete(album);
                },
                onDismissed: (direction) async {
                  if (!LibraryPluginHooks.hasAction(_selectorPage, 'delete')) {
                    await ref.read(remoteAlbumProvider.notifier).deleteAlbum(album.id);
                  }
                },
                child: AlbumTile(album: album, isOwner: isOwner, onAlbumSelected: onAlbumSelected),
              ),
            );
          } else {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: AlbumTile(album: album, isOwner: isOwner, onAlbumSelected: onAlbumSelected),
            );
          }
        },
        itemCount: albums.length,
      ),
    );
  }
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({required this.albums, required this.userId, required this.onAlbumSelected});

  final List<RemoteAlbum> albums;
  final String? userId;
  final AlbumSelectorCallback onAlbumSelected;

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) {
      return SliverToBoxAdapter(
        child: Center(
          child: Padding(padding: const EdgeInsets.all(20.0), child: Text(context.t.album_search_not_found)),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 250,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: .7,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final album = albums[index];
          return _GridAlbumCard(album: album, userId: userId, onAlbumSelected: onAlbumSelected);
        }, childCount: albums.length),
      ),
    );
  }
}

class _GridAlbumCard extends ConsumerWidget {
  const _GridAlbumCard({required this.album, required this.userId, required this.onAlbumSelected});

  final RemoteAlbum album;
  final String? userId;
  final AlbumSelectorCallback onAlbumSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumThumbnailAsset = ref.watch(assetServiceProvider).getRemoteAsset(album.thumbnailAssetId ?? "");

    return GestureDetector(
      onTap: () => onAlbumSelected(album),
      child: Card(
        elevation: 0,
        color: context.colorScheme.surfaceBright,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: context.colorScheme.onSurface.withAlpha(25), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                child: SizedBox(
                  width: double.infinity,
                  child: FutureBuilder(
                    future: albumThumbnailAsset,
                    builder: (context, snapshot) {
                      if (snapshot.hasData && snapshot.data != null) {
                        return Thumbnail.remote(
                          remoteId: album.thumbnailAssetId!,
                          thumbhash: snapshot.data!.thumbHash ?? "",
                        );
                      }

                      return ColoredBox(
                        color: context.colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.photo_album_rounded, size: 40, color: Colors.grey),
                      );
                    },
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Text(
                      album.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${context.t.items_count(count: album.assetCount)} • ${album.ownerId != userId ? context.t.shared_by_user(user: album.ownerName) : context.t.owned}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.labelMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AddToAlbumHeader extends ConsumerWidget {
  const AddToAlbumHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> onCreateAlbum() async {
      final albumName = await showDialog<String?>(context: context, builder: (context) => const NewAlbumNameModal());
      if (albumName == null || !context.mounted) {
        return;
      }

      final selectedAssets = ref.read(multiSelectProvider).selectedAssets;
      var ran = false;
      final newAlbum = await runLibraryAction<RemoteAlbum?>(
        context,
        _selectorPage,
        'createAlbum',
        () {
          ran = true;
          return ref.read(remoteAlbumProvider.notifier).createAlbumWithAssets(title: albumName, assets: selectedAssets);
        },
        args: () => {
          'scope': 'selection',
          'title': albumName,
          'assets': [for (final asset in selectedAssets) LibraryJson.asset(asset)],
        },
        withArgs: (args) {
          ran = true;
          return ref
              .read(remoteAlbumProvider.notifier)
              .createAlbumWithAssets(title: '${args['title'] ?? albumName}', assets: selectedAssets);
        },
      );
      // A plugin cancelled or handled it
      if (!ran && newAlbum == null) {
        return;
      }

      if (!context.mounted) {
        return;
      }

      if (newAlbum == null) {
        ImmichToast.show(context: context, toastType: ToastType.error, msg: context.t.errors.failed_to_create_album);
        return;
      }

      ref.read(multiSelectProvider.notifier).reset();
      unawaited(context.pushRoute(RemoteAlbumRoute(album: newAlbum)));
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverToBoxAdapter(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(context.t.add_to_album, style: context.textTheme.titleSmall),
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), // remove internal padding
                minimumSize: Size.zero, // allow shrinking
                tapTargetSize: MaterialTapTargetSize.shrinkWrap, // remove extra height
              ),
              onPressed: onCreateAlbum,
              icon: Icon(Icons.add, color: context.primaryColor),
              label: Text(
                context.t.common_create_new_album,
                style: TextStyle(color: context.primaryColor, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CreateAlbumButton extends ConsumerWidget {
  const CreateAlbumButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> onCreateAlbum() async {
      final albumName = await showDialog<String?>(context: context, builder: (context) => const NewAlbumNameModal());
      if (albumName == null || !context.mounted) {
        return;
      }

      final asset = ref.read(assetViewerProvider).currentAsset;

      if (asset == null) {
        ImmichToast.show(context: context, msg: "Cannot load asset information.", toastType: ToastType.error);
        return;
      }

      var ran = false;
      final album = await runLibraryAction<RemoteAlbum?>(
        context,
        _selectorPage,
        'createAlbum',
        () {
          ran = true;
          return ref.read(remoteAlbumProvider.notifier).createAlbum(title: albumName, assetIds: [asset.remoteId!]);
        },
        args: () => {
          'scope': 'viewer',
          'title': albumName,
          'assets': [LibraryJson.asset(asset)],
        },
        withArgs: (args) {
          ran = true;
          return ref
              .read(remoteAlbumProvider.notifier)
              .createAlbum(title: '${args['title'] ?? albumName}', assetIds: [asset.remoteId!]);
        },
      );

      // A plugin cancelled or handled it
      if (!context.mounted || (!ran && album == null)) {
        return;
      }

      if (album == null) {
        ImmichToast.show(context: context, toastType: ToastType.error, msg: context.t.errors.failed_to_create_album);
        return;
      }

      ImmichToast.show(
        context: context,
        msg: context.t.add_to_album_bottom_sheet_added(album: album.name),
      );

      // Invalidate using the asset's remote ID to refresh the "Appears in" list
      ref.invalidate(albumsContainingAssetProvider(asset.remoteId!));

      ContextHelper(context).pop();
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverToBoxAdapter(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(context.t.add_to_album, style: context.textTheme.titleSmall),
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onCreateAlbum,
              icon: Icon(Icons.add, color: context.primaryColor),
              label: Text(
                context.t.common_create_new_album,
                style: TextStyle(color: context.primaryColor, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
