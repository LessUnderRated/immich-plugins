import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Per-asset plugin data: small JSON values a plugin keeps per photo or video (`assetData.*` host functions).
///
/// Stored per plugin under `<plugins>/data/<plugin>/asset-data/<assetId>.json` (no database schema involved). Each
/// plugin sees only its own data. Asset ids are local or remote asset ids exactly as AssetV1 `id` carries them.
class PluginAssetData {
  final Future<Directory> Function() _pluginsRoot;
  final Map<String, Map<String, dynamic>> _cache = {};
  final Map<String, Future<void>> _locks = {};

  /// Emits `assetData.changed`; set by the kernel.
  void Function(String event, Map<String, dynamic> data)? emit;

  PluginAssetData(this._pluginsRoot);

  Future<Directory> _dir(String plugin) async =>
      Directory(p.join((await _pluginsRoot()).path, 'data', plugin, 'asset-data'));

  static String _fileName(String assetId) => '${Uri.encodeComponent(assetId)}.json';

  Future<File> _file(String plugin, String assetId) async => File(p.join((await _dir(plugin)).path, _fileName(assetId)));

  Future<Map<String, dynamic>> _read(String plugin, String assetId) async {
    final cacheKey = '$plugin\n$assetId';
    final cached = _cache[cacheKey];
    if (cached != null) {
      return cached;
    }
    final file = await _file(plugin, assetId);
    var data = <String, dynamic>{};
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          data = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        data = {};
      }
    }
    if (_cache.length > 512) {
      _cache.remove(_cache.keys.first);
    }
    return _cache[cacheKey] = data;
  }

  /// Serializes writes per plugin so concurrent `set` calls do not lose updates.
  Future<T> _locked<T>(String plugin, Future<T> Function() body) {
    final previous = _locks[plugin] ?? Future<void>.value();
    final result = previous.then((_) => body());
    _locks[plugin] = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _write(String plugin, String assetId, Map<String, dynamic> data) async {
    final file = await _file(plugin, assetId);
    if (data.isEmpty) {
      if (file.existsSync()) {
        await file.delete();
      }
      return;
    }
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    await temp.rename(file.path);
  }

  /// One value, or the whole map of [assetId] when [key] is null.
  Future<Object?> get(String plugin, String assetId, [String? key]) async {
    final data = await _read(plugin, assetId);
    return key == null ? Map<String, dynamic>.of(data) : data[key];
  }

  /// Stores [value] (any JSON value; null deletes the key).
  Future<void> set(String plugin, String assetId, String key, Object? value) => _locked(plugin, () async {
    final data = await _read(plugin, assetId);
    value == null ? data.remove(key) : data[key] = value;
    await _write(plugin, assetId, data);
    emit?.call('assetData.changed', {'plugin': plugin, 'assetId': assetId, 'key': key, 'value': value});
  });

  /// Deletes one key, or everything stored for [assetId] when [key] is null.
  Future<void> delete(String plugin, String assetId, [String? key]) => _locked(plugin, () async {
    final data = await _read(plugin, assetId);
    key == null ? data.clear() : data.remove(key);
    await _write(plugin, assetId, data);
    emit?.call('assetData.changed', {'plugin': plugin, 'assetId': assetId, 'key': key, 'value': null});
  });

  /// Keys stored for [assetId].
  Future<List<String>> keys(String plugin, String assetId) async => (await _read(plugin, assetId)).keys.toList();

  /// Asset ids that have data from [plugin].
  Future<List<String>> assets(String plugin) async {
    final directory = await _dir(plugin);
    if (!directory.existsSync()) {
      return const [];
    }
    return [
      for (final entity in directory.listSync())
        if (entity is File && entity.path.endsWith('.json')) Uri.decodeComponent(p.basenameWithoutExtension(entity.path)),
    ];
  }
}
