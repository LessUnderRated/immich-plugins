import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/domain/models/time_range.model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_json.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/map_plugin_layers.dart';
import 'package:immich_mobile/models/folder/recursive_folder.model.dart';
import 'package:immich_mobile/models/folder/root_folder.model.dart';
import 'package:immich_mobile/presentation/pages/album.page.dart';
import 'package:immich_mobile/presentation/pages/search/paginated_search.provider.dart';
import 'package:immich_mobile/presentation/pages/search/search.page.dart';
import 'package:immich_mobile/presentation/widgets/album/album_selector.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart';
import 'package:immich_mobile/presentation/widgets/map/map_utils.dart';
import 'package:immich_mobile/providers/folder.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/search.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/map/map_plugin_layers.provider.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/shared_link.service.dart';
import 'package:immich_mobile/utils/people.utils.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// A host function: `(plugin, args) -> JSON result`. Thrown errors become `{ "success": false, "message" }`.
typedef LibraryHostFunction = Future<Object?> Function(String plugin, List<dynamic> args);

/// Host functions of the library area: opening pages and pickers, map layers and camera, search, and the lists the
/// library pages show. Data operations (create / update / delete albums, assets, ...) are the data area's.
///
/// Phase B registers [all] with `kernel.registerHost(name, fn, doc: docs[name])`.
class LibraryHostFunctions {
  final Ref _ref;

  LibraryHostFunctions(this._ref);

  AppRouter get _router => _ref.read(appRouterProvider);

  /// The context of the app's navigator, for dialogs and sheets.
  BuildContext get _context {
    final context = _router.navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      throw StateError('The app has no screen to show this on');
    }
    return context;
  }

  /// Short `args -> result` docs, by name (also in `docs/plugins/library.md`).
  static const docs = <String, String>{
    'albums.open': '[albumId, { kind?: "remote"|"app"|"device" }] -> bool (opens the album page)',
    'albums.openList': '[{ kind?: "remote"|"device" }] -> true',
    'albums.openOptions': '[albumId] -> bool',
    'albums.openCreate': '[] -> true',
    'albums.openActivities': '[albumId, { assetId? }] -> bool',
    'albums.pick': '[{ title? }] -> Album | null (album picker sheet)',
    'albums.pickUsers': '[albumId] -> [userId] | null (invite picker; does not share)',
    'people.open': '[personId] -> bool',
    'people.openList': '[] -> true',
    'people.editName': '[personId] -> name | null (built-in dialog)',
    'people.editBirthday': '[personId] -> ISO date | null (built-in dialog)',
    'places.open': '[city] -> true',
    'places.openList': '[{ lat?, lng? }] -> true',
    'places.list': '[] -> [Place]',
    'search.open': '[SearchFilter?] -> true',
    'search.setFilter': '[SearchFilter] -> true (applies to the open search page)',
    'search.run': '[SearchFilter, { page? }] -> { assets: [Asset], nextPage }',
    'search.state': '[] -> { filter, count, nextPage, loading }',
    'map.open': '[{ lat?, lng? }] -> true',
    'map.pickLocation': '[{ lat?, lng? }] -> { lat, lng } | null',
    'map.layers.set': '[layerId, MapLayer] -> { layer, features }',
    'map.layers.remove': '[layerId] -> bool',
    'map.layers.setVisible': '[layerId, visible] -> bool',
    'map.layers.clear': '[] -> count',
    'map.layers.list': '[] -> [MapLayer]',
    'map.markers.set': '[layerId, [Marker]] -> { layer, features }',
    'map.camera.get': '[] -> { lat, lng, zoom, bounds } | null (null without an open map)',
    'map.camera.move': '[{ lat, lng, zoom?, animate? } | { bounds, padding? }] -> bool',
    'map.settings.get': '[] -> MapSettings',
    'map.settings.set':
        '[{ themeMode?, onlyFavorites?, includeArchived?, withPartners?, relativeDays?, timeRange? }] -> MapSettings',
    'folders.open': '[path?] -> bool',
    'folders.list': '[path?] -> [Folder]',
    'partners.list': '[{ direction?: "sharedWith"|"sharedBy" }] -> [Partner]',
    'partners.open': '[userId] -> bool',
    'partners.openList': '[] -> true',
    'sharedLinks.list': '[] -> [SharedLink]',
    'sharedLinks.open': '[linkId?] -> bool',
    'sharedLinks.openCreate': '[{ albumId?, assetIds? }] -> true',
    'library.open': '[] -> true',
    'lockedFolder.open': '[] -> true (asks for the PIN)',
    'private.open': '[] -> true',
    'private.isUnlocked': '[] -> bool',
    'private.lock': '[] -> true',
    'downloads.open': '[] -> true',
  };

  Map<String, LibraryHostFunction> get all => {
    'albums.open': _albumsOpen,
    'albums.openList': _albumsOpenList,
    'albums.openOptions': (_, args) async =>
        _openRemoteAlbum(_string(args, 0), (album) => AlbumOptionsRoute(album: album)),
    'albums.openCreate': (_, _) async => _push(const CreateAlbumRoute()),
    'albums.openActivities': (_, args) async => _openRemoteAlbum(
      _string(args, 0),
      (album) => ActivitiesRoute(album: album, assetId: _map(args, 1)['assetId'] as String?),
    ),
    'albums.pick': _albumsPick,
    'albums.pickUsers': _albumsPickUsers,
    'people.open': (_, args) async {
      final person = await _person(_string(args, 0));
      return person != null && _push(PersonRoute(person: person));
    },
    'people.openList': (_, _) async => _push(const PeopleCollectionRoute()),
    'people.editName': (_, args) async {
      final person = await _person(_string(args, 0));
      if (person == null) {
        return null;
      }
      final context = _context;
      return context.mounted ? showNameEditModal(context, person) : null;
    },
    'people.editBirthday': (_, args) async {
      final person = await _person(_string(args, 0));
      if (person == null) {
        return null;
      }
      final context = _context;
      final date = context.mounted ? await showBirthdayEditModal(context, person) : null;
      return date?.toIso8601String();
    },
    'places.open': (_, args) async => _push(PlaceDetailRoute(place: _string(args, 0))),
    'places.openList': (_, args) async => _push(PlaceRoute(currentLocation: _latLng(_map(args, 0)))),
    'places.list': (_, _) async => [
      for (final place in await _ref.read(placesProvider.future)) LibraryJson.place(place),
    ],
    'search.open': _searchOpen,
    'search.setFilter': (_, args) async {
      _ref.read(searchPreFilterProvider.notifier).setFilter(LibraryJson.searchFilterFromJson(_arg(args, 0)));
      return true;
    },
    'search.run': _searchRun,
    'search.state': (_, _) async {
      final state = _ref.read(paginatedSearchProvider);
      final filter = _ref.read(paginatedSearchProvider.notifier).filter;
      return {
        'filter': filter == null ? null : LibraryJson.searchFilter(filter),
        'count': state.assets.length,
        'nextPage': state.nextPage,
        'loading': state.isLoading,
      };
    },
    'map.open': (_, args) async => _push(MapRoute(initialLocation: _latLng(_map(args, 0)))),
    'map.pickLocation': (_, args) async {
      final picked = await _router.push<LatLng?>(
        MapLocationPickerRoute(initialLatLng: _latLng(_map(args, 0)) ?? const LatLng(0, 0)),
      );
      return picked == null ? null : {'lat': picked.latitude, 'lng': picked.longitude};
    },
    'map.layers.set': (plugin, args) async => _setLayer(plugin, _string(args, 0), _map(args, 1)),
    'map.markers.set': (plugin, args) async => _setLayer(plugin, _string(args, 0), {'markers': _arg(args, 1)}),
    'map.layers.remove': (plugin, args) async =>
        _ref.read(mapPluginLayersProvider.notifier).remove(plugin, _string(args, 0)),
    'map.layers.setVisible': (plugin, args) async =>
        _ref.read(mapPluginLayersProvider.notifier).setVisible(plugin, _string(args, 0), _arg(args, 1) != false),
    'map.layers.clear': (plugin, _) async => _ref.read(mapPluginLayersProvider.notifier).clear(plugin),
    'map.layers.list': (plugin, _) async => [
      for (final layer in _ref.read(mapPluginLayersProvider.notifier).of(plugin)) layer.toJson(),
    ],
    'map.camera.get': _cameraGet,
    'map.camera.move': _cameraMove,
    'map.settings.get': (_, _) async => mapSettingsJson(_ref.read(mapStateProvider)),
    'map.settings.set': _mapSettingsSet,
    'folders.open': _foldersOpen,
    'folders.list': (_, args) async {
      final folder = await _folder(args.isEmpty ? null : _arg(args, 0) as String?);
      return folder == null ? null : [for (final sub in folder.subfolders) LibraryJson.folder(sub)];
    },
    'partners.list': (_, args) async => [
      for (final partner in await _partners(_map(args, 0))) LibraryJson.partner(partner),
    ],
    'partners.open': (_, args) async {
      final id = _string(args, 0);
      final partner = (await _partners(const {'direction': 'sharedWith'})).firstWhereOrNull((p) => p.id == id);
      return partner != null && _push(PartnerDetailRoute(partner: partner));
    },
    'partners.openList': (_, _) async => _push(const PartnerRoute()),
    'sharedLinks.list': (_, _) async => [for (final link in await _sharedLinks()) LibraryJson.sharedLink(link)],
    'sharedLinks.open': (_, args) async {
      if (args.isEmpty || _arg(args, 0) == null) {
        return _push(const SharedLinkRoute());
      }
      final id = _string(args, 0);
      final link = (await _sharedLinks()).firstWhereOrNull((link) => link.id == id);
      return link != null && _push(SharedLinkEditRoute(existingLink: link));
    },
    'sharedLinks.openCreate': (_, args) async {
      final options = _map(args, 0);
      final assetIds = options['assetIds'];
      return _push(
        SharedLinkEditRoute(
          albumId: options['albumId'] as String?,
          assetsList: assetIds is List ? [for (final id in assetIds) '$id'] : null,
        ),
      );
    },
    'library.open': (_, _) async => _push(const LibraryRoute()),
    'lockedFolder.open': (_, _) async => _push(const LockedFolderRoute()),
    'private.open': (_, _) async {
      unawaited(_router.navigate(const PrivateGalleryRoute()));
      return true;
    },
    'private.isUnlocked': (_, _) async => _ref.read(privateUnlockedProvider),
    'private.lock': (_, _) async {
      if (_ref.read(privateUnlockedProvider)) {
        _ref.read(privateUnlockedProvider.notifier).state = false;
      }
      return true;
    },
    'downloads.open': (_, _) async => _push(const DownloadInfoRoute()),
  };

  // ---- helpers ----------------------------------------------------------------------------------------------------

  static Object? _arg(List<dynamic> args, int index) => index < args.length ? args[index] : null;

  static String _string(List<dynamic> args, int index) {
    final value = _arg(args, index);
    if (value == null) {
      throw ArgumentError('Argument ${index + 1} is required');
    }
    return '$value';
  }

  static Map<String, dynamic> _map(List<dynamic> args, int index) {
    final value = _arg(args, index);
    return value is Map ? Map<String, dynamic>.from(value) : const {};
  }

  static LatLng? _latLng(Map<String, dynamic> json) {
    final lat = json['lat'] ?? json['latitude'];
    final lng = json['lng'] ?? json['longitude'];
    return lat is num && lng is num ? LatLng(lat.toDouble(), lng.toDouble()) : null;
  }

  /// Opens [route] without waiting for it to close.
  bool _push(PageRouteInfo route) {
    unawaited(_router.push(route));
    return true;
  }

  Future<bool> _openRemoteAlbum(String id, PageRouteInfo Function(RemoteAlbum album) route) async {
    final album = await _ref.read(remoteAlbumServiceProvider).get(id);
    return album != null && _push(route(album));
  }

  Future<Person?> _person(String id) => _ref.read(Store.people.byId(id).future);

  // ---- albums -----------------------------------------------------------------------------------------------------

  Future<Object?> _albumsOpen(String plugin, List<dynamic> args) async {
    final id = _string(args, 0);
    switch (_map(args, 1)['kind']) {
      case 'app':
        return _push(AppAlbumRoute(albumId: id));
      case 'device':
        final album = (await _ref.read(localAlbumProvider.future)).firstWhereOrNull((album) => album.id == id);
        return album != null && _push(LocalTimelineRoute(album: album));
      default:
        return _openRemoteAlbum(id, (album) => RemoteAlbumRoute(album: album));
    }
  }

  Future<Object?> _albumsOpenList(String plugin, List<dynamic> args) async {
    if (_map(args, 0)['kind'] == 'device') {
      unawaited(_router.navigate(const LocalAlbumsRoute()));
      return true;
    }
    // The server album list has no registered route of its own
    unawaited(_router.pushWidget(const Scaffold(body: AlbumsPage())));
    return true;
  }

  Future<Object?> _albumsPick(String plugin, List<dynamic> args) async {
    final title = _map(args, 0)['title'] as String?;
    final album = await showModalBottomSheet<RemoteAlbum>(
      context: _context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (context, controller) => CustomScrollView(
          controller: controller,
          slivers: [
            if (title != null)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ),
            AlbumSelector(scope: 'plugin', onAlbumSelected: (album) => Navigator.of(context).pop(album)),
          ],
        ),
      ),
    );
    return album == null ? null : LibraryJson.remoteAlbum(album);
  }

  Future<Object?> _albumsPickUsers(String plugin, List<dynamic> args) async {
    final album = await _ref.read(remoteAlbumServiceProvider).get(_string(args, 0));
    if (album == null) {
      return null;
    }
    return _router.push<List<String>>(UserSelectionRoute(album: album));
  }

  // ---- search -----------------------------------------------------------------------------------------------------

  Future<Object?> _searchOpen(String plugin, List<dynamic> args) async {
    final filter = _arg(args, 0);
    if (filter is Map) {
      _ref.read(searchPreFilterProvider.notifier).setFilter(LibraryJson.searchFilterFromJson(filter));
    }
    // The search page has no registered route of its own
    unawaited(_router.pushWidget(const SearchPage()));
    return true;
  }

  Future<Object?> _searchRun(String plugin, List<dynamic> args) async {
    final filter = LibraryJson.searchFilterFromJson(_arg(args, 0));
    final page = _map(args, 1)['page'];
    final result = await _ref.read(searchServiceProvider).search(filter, page is num ? page.toInt() : 1);
    return {
      'assets': [for (final asset in result?.assets ?? const []) LibraryJson.asset(asset)],
      'nextPage': result?.nextPage,
    };
  }

  // ---- map --------------------------------------------------------------------------------------------------------

  Map<String, dynamic> _setLayer(String plugin, String id, Map<String, dynamic> json) {
    final layer = MapPluginLayer.fromJson(plugin, id, json);
    _ref.read(mapPluginLayersProvider.notifier).put(layer);
    return {'layer': layer.id, 'features': layer.features.length};
  }

  Future<Object?> _cameraGet(String plugin, List<dynamic> args) async {
    final controller = _ref.read(mapViewHandleProvider).controller;
    if (controller == null) {
      return null;
    }
    final position = controller.cameraPosition;
    final bounds = await controller.getVisibleRegion();
    return {
      'lat': position?.target.latitude,
      'lng': position?.target.longitude,
      'zoom': position?.zoom,
      'bounds': mapBoundsJson(bounds),
    };
  }

  Future<Object?> _cameraMove(String plugin, List<dynamic> args) async {
    final controller = _ref.read(mapViewHandleProvider).controller;
    if (controller == null) {
      return false;
    }
    final options = _map(args, 0);
    final bounds = mapBoundsFromJson(options['bounds']);
    final target = _latLng(options);
    final zoom = options['zoom'];
    final CameraUpdate update;
    if (bounds != null) {
      final padding = options['padding'];
      final pad = padding is num ? padding.toDouble() : 32.0;
      update = CameraUpdate.newLatLngBounds(bounds, left: pad, top: pad, right: pad, bottom: pad);
    } else if (target != null) {
      update = zoom is num ? CameraUpdate.newLatLngZoom(target, zoom.toDouble()) : CameraUpdate.newLatLng(target);
    } else if (zoom is num) {
      update = CameraUpdate.zoomTo(zoom.toDouble());
    } else {
      throw ArgumentError('Give lat and lng, zoom, or bounds');
    }
    if (options['animate'] == false) {
      return await controller.moveCamera(update) ?? true;
    }
    return await controller.animateCamera(update, duration: const Duration(milliseconds: 600)) ?? true;
  }

  Future<Object?> _mapSettingsSet(String plugin, List<dynamic> args) async {
    final options = _map(args, 0);
    final notifier = _ref.read(mapStateProvider.notifier);
    if (options['themeMode'] case final String mode) {
      notifier.switchTheme(ThemeMode.values.firstWhere((value) => value.name == mode, orElse: () => ThemeMode.system));
    }
    if (options['onlyFavorites'] case final bool value) {
      notifier.switchFavoriteOnly(value);
    }
    if (options['includeArchived'] case final bool value) {
      notifier.switchIncludeArchived(value);
    }
    if (options['withPartners'] case final bool value) {
      notifier.switchWithPartners(value);
    }
    if (options['relativeDays'] case final num value) {
      notifier.setRelativeTime(value.toInt());
    }
    if (options['timeRange'] case final Map range) {
      DateTime? date(Object? value) => value is String ? DateTime.tryParse(value) : null;
      notifier.setCustomTimeRange(TimeRange(from: date(range['from']), to: date(range['to'])));
    }
    return mapSettingsJson(_ref.read(mapStateProvider));
  }

  // ---- folders, partners, shared links ----------------------------------------------------------------------------

  /// The folder at [path] (the root when null), loading the folder structure if needed.
  Future<RootFolder?> _folder(String? path) async {
    var state = _ref.read(folderStructureProvider);
    if (!state.hasValue) {
      await _ref.read(folderStructureProvider.notifier).fetchFolders(SortOrder.asc);
      state = _ref.read(folderStructureProvider);
    }
    final root = state.valueOrNull;
    if (root == null || path == null || path.isEmpty || path == '/') {
      return root;
    }
    RootFolder? find(RootFolder folder) {
      for (final sub in folder.subfolders) {
        final full = sub.path.isEmpty ? sub.name : '${sub.path}/${sub.name}';
        if (full == path || sub.path == path || '/$full' == path) {
          return sub;
        }
        final found = find(sub);
        if (found != null) {
          return found;
        }
      }
      return null;
    }

    return find(root);
  }

  Future<Object?> _foldersOpen(String plugin, List<dynamic> args) async {
    final path = args.isEmpty ? null : _arg(args, 0) as String?;
    if (path == null || path.isEmpty || path == '/') {
      return _push(FolderRoute());
    }
    final folder = await _folder(path);
    return folder is RecursiveFolder && _push(FolderRoute(folder: folder));
  }

  Future<List<dynamic>> _partners(Map<String, dynamic> options) async {
    final user = _ref.read(currentUserProvider);
    if (user == null) {
      return const [];
    }
    final direction = options['direction'] == 'sharedBy' ? PartnerDirection.sharedBy : PartnerDirection.sharedWith;
    return (await _ref.read(partnerServiceProvider).search(user.id, direction).first).toList();
  }

  Future<List<dynamic>> _sharedLinks() async {
    final result = await _ref.read(sharedLinkServiceProvider).getAllSharedLinks();
    return result.valueOrNull ?? const [];
  }

  /// Every id this class registers, for checks against the catalog.
  static List<String> get names => docs.keys.toList();

  /// Library events (for `kernel.events` introspection).
  static List<String> get events => LibraryEvents.all;
}
