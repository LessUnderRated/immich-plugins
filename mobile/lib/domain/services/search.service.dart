import 'package:immich_mobile/domain/models/search_result.model.dart';
import 'package:immich_mobile/domain/models/tag.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/extensions/asset_extensions.dart';
import 'package:immich_mobile/extensions/string_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/search_api.repository.dart';
import 'package:immich_mobile/models/search/search_filter.model.dart';
import 'package:immich_mobile/utils/option.dart';
import 'package:logging/logging.dart';

class SearchService {
  final _log = Logger("SearchService");
  final SearchApiRepository _searchApiRepository;

  SearchService(this._searchApiRepository);

  /// Runs as `search.query`: `before` may change `page` or cancel, `instead` may answer with
  /// `{ assets: [AssetLite], nextPage }` (e.g. a local search), `after` may filter, sort or extend `assets`.
  Future<SearchResult?> search(SearchFilter filter, int page) => PluginHooks.run<SearchResult?>(
    DataHooks.searchQuery,
    () => {'filter': searchFilterJson(filter), 'page': page},
    () => _search(filter, page),
    withArgs: (args) => _search(filter, PluginArgs.integer(args['page']) ?? page),
    encode: (result) => result == null
        ? null
        : {
            'assets': [for (final asset in result.assets) PluginJson.asset(asset)],
            'nextPage': result.nextPage,
          },
    decode: (json) {
      if (json is! Map) {
        return null;
      }
      final assets = [for (final entry in json['assets'] is List ? json['assets'] as List : const []) ?PluginJson.parseAsset(entry)];
      return assets.isEmpty ? null : SearchResult(assets: assets, nextPage: PluginArgs.integer(json['nextPage']));
    },
  );

  static Map<String, dynamic> searchFilterJson(SearchFilter filter) => {
    'context': filter.context,
    'filename': filter.filename,
    'description': filter.description,
    'ocr': filter.ocr,
    'language': filter.language,
    'assetId': filter.assetId,
    'tags': [for (final tag in filter.tags ?? const <Tag>{}) PluginJson.tag(tag)],
    'people': [for (final person in filter.people) PluginJson.person(person)],
    'country': filter.location.country,
    'state': filter.location.state,
    'city': filter.location.city,
    'make': filter.camera.make,
    'model': filter.camera.model,
    'takenBefore': PluginJson.iso(filter.date.takenBefore),
    'takenAfter': PluginJson.iso(filter.date.takenAfter),
    if (filter.rating.rating case Some(:final value)) 'rating': value,
    'isNotInAlbum': filter.display.isNotInAlbum,
    'isArchive': filter.display.isArchive,
    'isFavorite': filter.display.isFavorite,
    'mediaType': PluginJson.assetType(filter.mediaType),
  };

  Future<SearchResult?> _search(SearchFilter filter, int page) async {
    try {
      final response = await _searchApiRepository.search(filter, page);

      if (response == null || response.assets.items.isEmpty) {
        return null;
      }

      return SearchResult(
        assets: response.assets.items.map((e) => e.toDto()).toList(),
        nextPage: response.assets.nextPage?.toInt(),
      );
    } catch (error, stackTrace) {
      _log.severe("Failed to search for assets", error, stackTrace);
    }
    return null;
  }
}
