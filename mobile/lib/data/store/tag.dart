import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/server/tag.dart';
import 'package:immich_mobile/data/store/util/cache.dart';
import 'package:immich_mobile/domain/models/tag.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger("TagStore");

/// User defined tags that can be applied to assets
///
/// All operations directly access the HTTP API only
extension type const TagStore._(Provider<TagMutations> _provider) implements Provider<TagMutations> {
  static final TagStore instance = TagStore._(Provider((ref) => TagMutations._(ref)));

  /// Every tag known to the server
  ///
  /// **NOTE:** This is not reactive to changes, and only hits the HTTP API
  AutoDisposeFutureProvider<List<Tag>> all() => _allProvider;

  /// The tags applied to the asset [assetId]
  ///
  /// **NOTE:** This is not reactive to changes, and only hits the HTTP API. Invalidate the whole family after a
  /// mutation, since a single change can affect many assets
  AutoDisposeFutureProviderFamily<List<Tag>, String> get forAsset => _forAssetProvider;
}

final _allProvider = FutureProvider.autoDispose<List<Tag>>((ref) async {
  final List<Tag> tags;
  try {
    tags = await ref.watch(tagApiRepositoryProvider).getAll();
  } catch (error, stack) {
    _log.severe("Failed to get all tags", error, stack);
    return const [];
  }
  return PluginHooks.filterList<Tag>(DataHooks.tagQuery, () => {'source': 'remote'}, tags, PluginJson.tags);
});

final _forAssetProvider = FutureProvider.autoDispose.family<List<Tag>, String>(
  (ref, assetId) => ref.watch(assetServiceProvider).getTags(assetId),
);

class TagMutations extends StoreMutations {
  const TagMutations._(super.ref);

  /// Create the tags named [values], returning the list of successfully created (or pre-existing) tags
  Future<List<Tag>> upsert(List<String> values) => PluginHooks.run<List<Tag>>(
    DataHooks.tagCreate,
    () => {'values': values, 'source': 'remote'},
    () => _upsert(values),
    withArgs: (args) => _upsert(PluginArgs.strings(args['values'])),
    encode: (tags) => [for (final tag in tags) PluginJson.tag(tag)],
    decode: (json) => [
      for (final entry in json is List ? json : const [])
        if (entry is Map && entry['id'] is String && entry['value'] is String)
          Tag(id: entry['id'] as String, value: entry['value'] as String),
    ],
    event: DataEvents.tagCreated,
    eventData: (args, tags) => {
      ...args,
      'tags': [for (final tag in tags) PluginJson.tag(tag)],
    },
  );

  Future<List<Tag>> _upsert(List<String> values) async {
    try {
      return await read(tagApiRepositoryProvider).upsert(values);
    } catch (error, stack) {
      _log.severe("Failed to upsert tags", error, stack);
      rethrow;
    }
  }

  /// Apply every tag in [tagIds] to every asset in [assetIds], returning the number of assets successfully tagged
  Future<int> applyToAssets(List<String> assetIds, List<String> tagIds) => PluginHooks.run<int>(
    DataHooks.tagAssign,
    () => {'assetIds': assetIds, 'tagIds': tagIds, 'source': 'remote'},
    () => _applyToAssets(assetIds, tagIds),
    withArgs: (args) => _applyToAssets(PluginArgs.strings(args['assetIds']), PluginArgs.strings(args['tagIds'])),
    encode: (count) => count,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.tagAssigned,
    eventData: (args, count) => {...args, 'count': count},
  );

  Future<int> _applyToAssets(List<String> assetIds, List<String> tagIds) async {
    try {
      return await read(tagApiRepositoryProvider).bulkTagAssets(assetIds, tagIds);
    } catch (error, stack) {
      _log.severe("Failed to tag assets", error, stack);
      rethrow;
    }
  }

  /// Remove the tag [tagId] from every asset in [assetIds], returning the number of assets successfully untagged
  Future<int> removeFromAssets(String tagId, List<String> assetIds) => PluginHooks.run<int>(
    DataHooks.tagUnassign,
    () => {'tagId': tagId, 'assetIds': assetIds, 'source': 'remote'},
    () => _removeFromAssets(tagId, assetIds),
    withArgs: (args) =>
        _removeFromAssets(PluginArgs.string(args['tagId']) ?? tagId, PluginArgs.strings(args['assetIds'])),
    encode: (count) => count,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.tagUnassigned,
    eventData: (args, count) => {...args, 'count': count},
  );

  Future<int> _removeFromAssets(String tagId, List<String> assetIds) async {
    try {
      return await read(tagApiRepositoryProvider).untagAssets(tagId, assetIds);
    } catch (error, stack) {
      _log.severe("Failed to untag assets", error, stack);
      rethrow;
    }
  }
}
