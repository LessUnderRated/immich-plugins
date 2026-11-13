import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/search_result.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/search.service.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_json.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/models/search/search_filter.model.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/search.provider.dart';

final searchPreFilterProvider = NotifierProvider<SearchFilterProvider, SearchFilter?>(SearchFilterProvider.new);

class SearchFilterProvider extends Notifier<SearchFilter?> {
  @override
  SearchFilter? build() {
    return null;
  }

  void setFilter(SearchFilter? filter) {
    state = filter;
  }

  void clear() {
    state = null;
  }
}

class SearchState {
  final List<BaseAsset> assets;
  final int? nextPage;
  final bool isLoading;

  const SearchState({this.assets = const [], this.nextPage = 1, this.isLoading = false});
}

final paginatedSearchProvider = StateNotifierProvider<PaginatedSearchNotifier, SearchState>(
  (ref) => PaginatedSearchNotifier(
    ref.watch(searchServiceProvider),
    ref.watch(driftProvider).remoteAssetRepository,
    assetService: ref.watch(assetServiceProvider),
  ),
);

/// Runs one page of a search through the `search.query` plugin hook.
///
/// `before` may change `filter` / `page` or cancel (no results); `instead` may answer the search itself;
/// `after` may filter, sort or extend `{ "assets", "nextPage" }`. Assets a plugin adds by id (remote or local) are
/// looked up; ids that do not resolve are dropped. Without a plugin on the hook this is `service.search()`.
Future<SearchResult?> runSearchQuery(
  SearchService service,
  SearchFilter filter,
  int page, {
  AssetService? assetService,
}) async {
  if (!LibraryPluginHooks.has(LibraryHooks.searchQuery)) {
    return service.search(filter, page);
  }

  final known = <String, BaseAsset>{};
  _SearchPage? toPage(SearchResult? result) => result == null ? null : _SearchPage([...result.assets], result.nextPage);

  _SearchPage? hooked;
  try {
    hooked = await LibraryPluginHooks.flow<_SearchPage?>(
      LibraryHooks.searchQuery,
      () async => toPage(await service.search(filter, page)),
      args: () => {'filter': LibraryJson.searchFilter(filter), 'page': page},
      withArgs: (args) async {
        final changed = LibraryJson.searchFilterFromJson(args['filter'], base: filter);
        final changedPage = args['page'];
        return toPage(await service.search(changed, changedPage is num ? changedPage.toInt() : page));
      },
      encode: (value) {
        if (value == null) {
          return null;
        }
        final assets = [
          for (final item in value.items)
            if (item is BaseAsset) item,
        ];
        for (final asset in assets) {
          known[asset.id] = asset;
          if (asset.remoteId case final remoteId?) {
            known[remoteId] = asset;
          }
          if (asset.localId case final localId?) {
            known[localId] = asset;
          }
        }
        return {
          'assets': [for (final asset in assets) LibraryJson.asset(asset)],
          'nextPage': value.nextPage,
        };
      },
      decode: (json) => _SearchPage.fromJson(json, known),
    );
  } catch (error) {
    if (LibraryPluginHooks.isCancelled(error)) {
      return null;
    }
    rethrow;
  }

  if (hooked == null) {
    return null;
  }
  final assets = <BaseAsset>[];
  for (final item in hooked.items) {
    if (item is BaseAsset) {
      assets.add(item);
    } else if (item is _AssetRef && assetService != null) {
      final asset = item.local ? await assetService.getLocalAsset(item.id) : await assetService.getRemoteAsset(item.id);
      if (asset != null) {
        assets.add(asset);
      }
    }
  }
  return SearchResult(assets: assets, nextPage: hooked.nextPage);
}

/// An asset a plugin added to search results by id.
class _AssetRef {
  final String id;
  final bool local;

  const _AssetRef(this.id, {required this.local});
}

class _SearchPage {
  /// [BaseAsset]s and [_AssetRef]s.
  final List<Object> items;
  final int? nextPage;

  const _SearchPage(this.items, this.nextPage);

  /// Reads `{ "assets": [id or { "id" | "remoteId" | "localId" }], "nextPage"? }` or a bare list.
  static _SearchPage? fromJson(Object? json, Map<String, BaseAsset> known) {
    if (json == null) {
      return null;
    }
    final list = json is Map ? json['assets'] : json;
    final nextPage = json is Map && json['nextPage'] is num ? (json['nextPage'] as num).toInt() : null;
    final items = <Object>[];
    if (list is List) {
      for (final entry in list) {
        if (entry is String) {
          items.add(known[entry] ?? _AssetRef(entry, local: false));
          continue;
        }
        if (entry is! Map) {
          continue;
        }
        final id = entry['id'] ?? entry['remoteId'] ?? entry['localId'];
        final asset = known['${entry['id']}'] ?? known['${entry['remoteId']}'] ?? known['${entry['localId']}'];
        if (asset != null) {
          items.add(asset);
        } else if (entry['remoteId'] != null) {
          items.add(_AssetRef('${entry['remoteId']}', local: false));
        } else if (entry['localId'] != null) {
          items.add(_AssetRef('${entry['localId']}', local: true));
        } else if (id != null) {
          items.add(_AssetRef('$id', local: entry['isLocal'] == true && entry['isRemote'] != true));
        }
      }
    }
    return _SearchPage(items, nextPage);
  }
}

class PaginatedSearchNotifier extends StateNotifier<SearchState> {
  final SearchService _searchService;
  final RemoteAssetRepository _remoteAssetRepository;

  /// Looks up assets plugins add to results by id.
  final AssetService? assetService;
  final _assetCountController = StreamController<int>.broadcast();

  StreamSubscription<Set<String>>? _deletedIdsSubscription;
  List<BaseAsset> _results = const [];
  int? _nextPage = 1;
  SearchFilter? _filter;

  PaginatedSearchNotifier(this._searchService, this._remoteAssetRepository, {this.assetService})
    : super(const SearchState());

  Stream<int> get assetCount => _assetCountController.stream.distinct();

  /// The filter of the results shown, or null before the first search.
  SearchFilter? get filter => _filter;

  Future<void> search(SearchFilter filter) async {
    if (state.nextPage == null || state.isLoading) {
      return;
    }

    state = SearchState(assets: state.assets, nextPage: state.nextPage, isLoading: true);

    final page = state.nextPage!;
    final result = await runSearchQuery(_searchService, filter, page, assetService: assetService);

    if (!mounted) {
      return;
    }

    _filter = filter;
    if (result == null) {
      state = SearchState(assets: state.assets, nextPage: state.nextPage);
      _emitPerformed(filter, page, 0);
      return;
    }

    _results = [..._results, ...result.assets];
    _nextPage = result.nextPage;
    _watchDeletedIds(filter.display.isArchive ? AssetVisibility.archive : AssetVisibility.timeline);
    _emitPerformed(filter, page, result.assets.length);
  }

  void _emitPerformed(SearchFilter filter, int page, int count) => LibraryPluginHooks.emit(
    LibraryEvents.searchPerformed,
    () => {
      'filter': LibraryJson.searchFilter(filter),
      'page': page,
      'count': count,
      'total': _results.length,
      'nextPage': _nextPage,
    },
  );

  void clear() {
    unawaited(_deletedIdsSubscription?.cancel());
    _deletedIdsSubscription = null;
    _results = const [];
    _nextPage = 1;
    _filter = null;
    _emit(const {});
    LibraryPluginHooks.emit(LibraryEvents.searchCleared, () => const {});
  }

  void _watchDeletedIds(AssetVisibility visibility) {
    unawaited(_deletedIdsSubscription?.cancel());

    final ids = _results.whereType<RemoteAsset>().map((asset) => asset.id);
    _deletedIdsSubscription = _remoteAssetRepository.watchDeletedAssetIds(ids, visibility).listen(_emit);
  }

  void _emit(Set<String> deletedIds) {
    final visible = deletedIds.isEmpty
        ? _results
        : _results.where((asset) => asset is! RemoteAsset || !deletedIds.contains(asset.id)).toList(growable: false);

    state = SearchState(assets: visible, nextPage: _nextPage);
    _assetCountController.add(visible.length);
  }

  @override
  void dispose() {
    unawaited(_deletedIdsSubscription?.cancel());
    unawaited(_assetCountController.close());
    super.dispose();
  }
}
