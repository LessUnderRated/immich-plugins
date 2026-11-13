import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_json.dart';
import 'package:immich_mobile/pages/common/large_leading_tile.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/library/library_plugins.widget.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/search_field.dart';
import 'package:immich_mobile/widgets/map/map_thumbnail.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

const _page = LibraryPages.place;

@RoutePage()
class PlacePage extends StatelessWidget {
  const PlacePage({super.key, this.currentLocation});

  final LatLng? currentLocation;

  @override
  Widget build(BuildContext context) {
    final ValueNotifier<String?> search = ValueNotifier(null);

    return Scaffold(
      body: ValueListenableBuilder(
        valueListenable: search,
        builder: (context, searchValue, child) {
          return CustomScrollView(
            slivers: [
              _PlaceSliverAppBar(search: search),
              ...LibraryPluginHooks.arrange(LibrarySlots.placeSections, [
                (id: 'map', item: _Map(search: search, currentLocation: currentLocation)),
                (id: 'list', item: _PlaceList(search: search)),
              ]),
            ],
          );
        },
      ),
    );
  }
}

class _PlaceSliverAppBar extends HookWidget {
  const _PlaceSliverAppBar({required this.search});

  final ValueNotifier<String?> search;

  @override
  Widget build(BuildContext context) {
    final searchFocusNode = useFocusNode();

    return SliverAppBar(
      floating: true,
      pinned: true,
      snap: false,
      backgroundColor: context.colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(5))),
      automaticallyImplyLeading: search.value == null,
      centerTitle: true,
      title: search.value != null
          ? SearchField(
              focusNode: searchFocusNode,
              onTapOutside: (_) => searchFocusNode.unfocus(),
              onChanged: (value) => search.value = value,
              filled: true,
              hintText: context.t.filter_places,
              autofocus: true,
            )
          : Text(context.t.places),
      actions: LibraryPluginHooks.arrange(LibrarySlots.appBarActions(_page), [
        (
          id: 'search',
          item: IconButton(
            icon: Icon(search.value != null ? Icons.close : Icons.search),
            onPressed: () => libraryTap(context, _page, 'search', () {
              search.value = search.value == null ? '' : null;
            }, args: () => {'open': search.value == null}),
          ),
        ),
      ]),
    );
  }
}

class _Map extends StatelessWidget {
  const _Map({required this.search, this.currentLocation});

  final ValueNotifier<String?> search;
  final LatLng? currentLocation;

  @override
  Widget build(BuildContext context) {
    return search.value == null
        ? SliverPadding(
            padding: const EdgeInsets.all(16.0),
            sliver: SliverToBoxAdapter(
              child: SizedBox(
                height: 200,
                width: context.width,
                child: MapThumbnail(
                  onTap: (_, _) => libraryTap(
                    context,
                    _page,
                    'map',
                    () => context.pushRoute(MapRoute(initialLocation: currentLocation)),
                  ),
                  zoom: 8,
                  centre: currentLocation ?? const LatLng(21.44950, -157.91959),
                  showAttribution: false,
                  themeMode: context.isDarkTheme ? ThemeMode.dark : ThemeMode.light,
                ),
              ),
            ),
          )
        : const SliverToBoxAdapter(child: SizedBox.shrink());
  }
}

class _PlaceList extends ConsumerWidget {
  const _PlaceList({required this.search});

  final ValueNotifier<String?> search;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final places = ref.watch(placesProvider);

    return places.when(
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
              'Error loading places: $error, stack: $stack',
              style: TextStyle(color: context.colorScheme.error),
            ),
          ),
        ),
      ),
      data: (places) {
        final List<(String, String)> filtered;
        if (search.value != null) {
          filtered = places.where((place) {
            return place.$1.toLowerCase().contains(search.value!.toLowerCase());
          }).toList();
        } else {
          filtered = places;
        }

        return LibraryQueryBuilder<(String, String)>(
          hook: LibraryHooks.placesQuery,
          items: filtered,
          argsKey: search.value,
          id: (place) => place.$1,
          toJson: LibraryJson.place,
          fromJson: (json) {
            final name = json['name'] ?? json['id'];
            final assetId = json['assetId'];
            return name == null || assetId == null ? null : ('$name', '$assetId');
          },
          args: () => {'search': search.value},
          placeholder: (_) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          builder: (context, filtered) => SliverList.builder(
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final place = filtered[index];
              return _PlaceTile(place: place);
            },
          ),
        );
      },
    );
  }
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({required this.place});

  final (String, String) place;

  @override
  Widget build(BuildContext context) {
    return LargeLeadingTile(
      onTap: () => libraryTap(
        context,
        _page,
        'open',
        () => context.pushRoute(PlaceDetailRoute(place: place.$1)),
        args: () => {'place': LibraryJson.place(place)},
      ),
      title: Text(place.$1, style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        child: SizedBox(
          width: 80,
          height: 80,
          child: Thumbnail.remote(remoteId: place.$2, fit: BoxFit.cover, thumbhash: ""),
        ),
      ),
    );
  }
}
