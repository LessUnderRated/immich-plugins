import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';
import 'package:immich_mobile/infrastructure/repositories/device_tag.repository.dart';

/// Device tags (`tags.*`): tags are `/`-separated paths (`Trips/2024`) whose id is the value, usable on any asset
/// id. The same tags back `bulkTagAssets` and the `tags` of AssetV1.
class TagsHostApi implements DataHostModule {
  final DeviceTagRepository _tags;

  const TagsHostApi(this._tags);

  @override
  Map<String, DataHostFunction> get functions => {
    'tags.list': (plugin, args) async => [for (final tag in await _tags.all()) PluginJson.tag(tag)],
    'tags.create': (plugin, args) async => [
      for (final tag in await _tags.create(HostArgs(args).ids(0, 'values'))) PluginJson.tag(tag),
    ],
    'tags.delete': (plugin, args) async {
      await _tags.delete(HostArgs(args).text(0, 'id'));
      return null;
    },
    'tags.assign': (plugin, args) async => {
      'count': await _tags.assign(HostArgs(args).ids(0, 'assetIds'), HostArgs(args).ids(1, 'tagIds')),
    },
    'tags.unassign': (plugin, args) async => {
      'count': await _tags.unassign(HostArgs(args).text(0, 'tagId'), HostArgs(args).ids(1, 'assetIds')),
    },
    'tags.forAsset': (plugin, args) async => [
      for (final tag in await _tags.forAsset(HostArgs(args).text(0, 'assetId'))) PluginJson.tag(tag),
    ],
    'tags.assets': (plugin, args) => _tags.assetsWith(
      HostArgs(args).text(0, 'tagId'),
      includeChildren: HostArgs(args).map(1).flag('includeChildren') ?? false,
    ),
  };

  @override
  Map<String, String> get docs => const {
    'tags.list': '[] -> [{ id, value, name }]',
    'tags.create': '[values] -> [Tag]',
    'tags.delete': '[id] -> null (also removed from every asset)',
    'tags.assign': '[assetIds, tagIds] -> { count } (missing tags are created)',
    'tags.unassign': '[tagId, assetIds] -> { count }',
    'tags.forAsset': '[assetId] -> [Tag]',
    'tags.assets': '[tagId, { includeChildren? }] -> [assetId]',
  };
}
