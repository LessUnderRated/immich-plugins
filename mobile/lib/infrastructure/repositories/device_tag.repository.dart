import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/domain/models/tag.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Tags kept on the device for any asset id (device or server). A tag's id is its value, a `/`-separated path
/// such as `Trips/2024`, the same convention the `bulkTagAssets` host function and AssetV1 `tags` use.
class DeviceTagRepository {
  final _changes = StreamController<void>.broadcast();
  _TagState? _cache;

  Stream<void> get changes => _changes.stream;

  Future<File> _file() async => File(p.join((await getApplicationDocumentsDirectory()).path, 'tags.json'));

  Future<_TagState> _state() async {
    final cached = _cache;
    if (cached != null) {
      return cached;
    }
    final file = await _file();
    if (!file.existsSync()) {
      return _cache = const _TagState({}, {});
    }
    try {
      final json = Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map);
      final tags = <String, DateTime>{
        for (final entry in (json['tags'] as List? ?? const []).whereType<Map>())
          '${entry['value']}': DateTime.fromMillisecondsSinceEpoch((entry['createdAt'] as num?)?.toInt() ?? 0),
      };
      final assets = <String, Set<String>>{
        for (final entry in (json['assets'] as Map? ?? const {}).entries)
          '${entry.key}': {for (final tag in entry.value as List? ?? const []) '$tag'},
      };
      return _cache = _TagState(tags, assets);
    } catch (_) {
      return _cache = const _TagState({}, {});
    }
  }

  Future<void> _save(_TagState state) async {
    final file = await _file();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'tags': [
          for (final entry in state.tags.entries)
            {'value': entry.key, 'createdAt': entry.value.millisecondsSinceEpoch},
        ],
        'assets': {
          for (final entry in state.assets.entries)
            if (entry.value.isNotEmpty) entry.key: entry.value.toList(),
        },
      }),
      flush: true,
    );
    await temp.rename(file.path);
    _cache = state;
    _changes.add(null);
  }

  static Tag _tag(String value) => Tag(id: value, value: value);

  static List<Tag> _decodeTags(Object? json) => [
    for (final entry in json is List ? json : const [])
      if (_tagValue(entry) case final String value) _tag(value),
  ];

  static String? _tagValue(Object? entry) {
    final value = entry is Map ? entry['value'] : entry;
    return value == null ? null : _normalize('$value');
  }

  static String _normalize(String value) =>
      value.split('/').map((part) => part.trim()).where((part) => part.isNotEmpty).join('/');

  /// Every tag, sorted by value. Plugins can filter, sort or extend the list through `tag.query`.
  Future<List<Tag>> all() async {
    final state = await _state();
    final tags = (state.tags.keys.toList()..sort()).map(_tag).toList();
    return PluginHooks.filterList<Tag>(DataHooks.tagQuery, () => {'source': 'device'}, tags, PluginJson.tags);
  }

  Future<List<Tag>> forAsset(String assetId) async {
    final state = await _state();
    return ((state.assets[assetId] ?? const <String>{}).toList()..sort()).map(_tag).toList();
  }

  Future<Map<String, List<String>>> forAssets(Iterable<String> assetIds) async {
    final state = await _state();
    return {for (final id in assetIds) id: (state.assets[id] ?? const <String>{}).toList()..sort()};
  }

  /// Ids of the assets that carry [tagId] (or, with [includeChildren], any tag below it).
  Future<List<String>> assetsWith(String tagId, {bool includeChildren = false}) async {
    final state = await _state();
    return [
      for (final entry in state.assets.entries)
        if (entry.value.any((tag) => tag == tagId || (includeChildren && tag.startsWith('$tagId/')))) entry.key,
    ];
  }

  /// Creates tags (existing ones are kept); runs as `tag.create` with `source: "device"`.
  Future<List<Tag>> create(List<String> values) => PluginHooks.run<List<Tag>>(
    DataHooks.tagCreate,
    () => {'values': values, 'source': 'device'},
    () => _create(values),
    withArgs: (args) => _create(PluginArgs.strings(args['values'])),
    encode: (tags) => [for (final tag in tags) PluginJson.tag(tag)],
    decode: _decodeTags,
    event: DataEvents.tagCreated,
    eventData: (args, tags) => {
      ...args,
      'tags': [for (final tag in tags) PluginJson.tag(tag)],
    },
  );

  Future<List<Tag>> _create(List<String> values) async {
    final state = await _state();
    final normalized = values.map(_normalize).where((value) => value.isNotEmpty).toSet();
    final now = DateTime.now();
    final added = normalized.where((value) => !state.tags.containsKey(value)).toList();
    if (added.isNotEmpty) {
      await _save(_TagState({...state.tags, for (final value in added) value: now}, state.assets));
    }
    return normalized.map(_tag).toList();
  }

  /// Deletes a tag and removes it from every asset; runs as `tag.delete`.
  Future<void> delete(String tagId) => PluginHooks.run<void>(
    DataHooks.tagDelete,
    () => {'id': tagId, 'source': 'device'},
    () => _delete(tagId),
    withArgs: (args) => _delete(PluginArgs.string(args['id']) ?? tagId),
    event: DataEvents.tagDeleted,
  );

  Future<void> _delete(String tagId) async {
    final state = await _state();
    await _save(
      _TagState(
        {...state.tags}..remove(tagId),
        {for (final entry in state.assets.entries) entry.key: {...entry.value}..remove(tagId)},
      ),
    );
  }

  /// Adds every tag in [tagIds] (created when missing) to every asset; runs as `tag.assign`. Returns how many assets
  /// gained at least one tag.
  Future<int> assign(List<String> assetIds, List<String> tagIds) => PluginHooks.run<int>(
    DataHooks.tagAssign,
    () => {'assetIds': assetIds, 'tagIds': tagIds, 'source': 'device'},
    () => _assign(assetIds, tagIds),
    withArgs: (args) => _assign(PluginArgs.strings(args['assetIds']), PluginArgs.strings(args['tagIds'])),
    encode: (count) => count,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.tagAssigned,
    eventData: (args, count) => {...args, 'count': count},
  );

  Future<int> _assign(List<String> assetIds, List<String> tagIds) async {
    final state = await _state();
    final tags = tagIds.map(_normalize).where((value) => value.isNotEmpty).toSet();
    if (tags.isEmpty || assetIds.isEmpty) {
      return 0;
    }
    final now = DateTime.now();
    final assets = {for (final entry in state.assets.entries) entry.key: {...entry.value}};
    var changed = 0;
    for (final assetId in assetIds.toSet()) {
      final current = assets.putIfAbsent(assetId, () => <String>{});
      final before = current.length;
      current.addAll(tags);
      if (current.length != before) {
        changed++;
      }
    }
    await _save(_TagState({...state.tags, for (final tag in tags) tag: state.tags[tag] ?? now}, assets));
    return changed;
  }

  /// Removes [tagId] from the assets; runs as `tag.unassign`. Returns how many assets lost it.
  Future<int> unassign(String tagId, List<String> assetIds) => PluginHooks.run<int>(
    DataHooks.tagUnassign,
    () => {'tagId': tagId, 'assetIds': assetIds, 'source': 'device'},
    () => _unassign(tagId, assetIds),
    withArgs: (args) => _unassign(PluginArgs.string(args['tagId']) ?? tagId, PluginArgs.strings(args['assetIds'])),
    encode: (count) => count,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.tagUnassigned,
    eventData: (args, count) => {...args, 'count': count},
  );

  Future<int> _unassign(String tagId, List<String> assetIds) async {
    final state = await _state();
    final assets = {for (final entry in state.assets.entries) entry.key: {...entry.value}};
    var changed = 0;
    for (final assetId in assetIds.toSet()) {
      if (assets[assetId]?.remove(tagId) ?? false) {
        changed++;
      }
    }
    if (changed > 0) {
      await _save(_TagState(state.tags, assets));
    }
    return changed;
  }

  /// Drops the tags of assets that no longer exist.
  Future<void> forgetAssets(Iterable<String> assetIds) async {
    final state = await _state();
    final remove = assetIds.toSet();
    if (!state.assets.keys.any(remove.contains)) {
      return;
    }
    await _save(
      _TagState(state.tags, {
        for (final entry in state.assets.entries)
          if (!remove.contains(entry.key)) entry.key: entry.value,
      }),
    );
  }

  /// Merges tags kept elsewhere (asset id to tag values), e.g. the plugin engine's earlier tag state.
  Future<void> importAssetTags(Map<String, List<String>> assetTags) async {
    for (final entry in assetTags.entries) {
      await _assign([entry.key], entry.value);
    }
  }
}

class _TagState {
  /// Tag value to creation time.
  final Map<String, DateTime> tags;

  /// Asset id to tag values.
  final Map<String, Set<String>> assets;

  const _TagState(this.tags, this.assets);
}
