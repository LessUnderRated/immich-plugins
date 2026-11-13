import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PrivateAlbumRepository {
  final _changes = StreamController<void>.broadcast();
  Set<String>? _cache;

  Stream<void> get changes => _changes.stream;

  Set<String> get cached => _cache ?? const {};

  Future<File> _file() async => File(p.join((await getApplicationDocumentsDirectory()).path, 'private_ids.json'));

  Future<Set<String>> ids() async {
    final cached = _cache;
    if (cached != null) {
      return cached;
    }
    final file = await _file();
    if (!file.existsSync()) {
      return _cache = const {};
    }
    try {
      return _cache = (jsonDecode(await file.readAsString()) as List).map((id) => '$id').toSet();
    } catch (_) {
      return _cache = const {};
    }
  }

  Future<void> _save(Set<String> ids) async {
    final file = await _file();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(ids.toList()), flush: true);
    await temp.rename(file.path);
    _cache = Set.unmodifiable(ids);
    _changes.add(null);
  }

  /// Marks assets private (hidden from every other view); runs as `asset.private` with `private: true`.
  Future<int> add(Iterable<String> assetIds) => _setPrivate(assetIds.toList(), true);

  /// Unmarks private assets; runs as `asset.private` with `private: false`.
  Future<int> remove(Iterable<String> assetIds) => _setPrivate(assetIds.toList(), false);

  Future<int> _setPrivate(List<String> assetIds, bool private) => PluginHooks.run<int>(
    DataHooks.assetPrivate,
    () => {'ids': assetIds, 'private': private},
    () => private ? _add(assetIds) : _remove(assetIds),
    withArgs: (args) {
      final ids = PluginArgs.strings(args['ids']);
      return (PluginArgs.boolean(args['private']) ?? private) ? _add(ids) : _remove(ids);
    },
    encode: (changed) => changed,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.assetPrivateChanged,
    eventData: (args, changed) => {...args, 'changed': changed},
  );

  Future<int> _add(Iterable<String> assetIds) async {
    final current = await ids();
    final next = {...current, ...assetIds};
    await _save(next);
    return next.length - current.length;
  }

  Future<int> _remove(Iterable<String> assetIds) async {
    final current = await ids();
    final next = current.difference(assetIds.toSet());
    await _save(next);
    return current.length - next.length;
  }
}
