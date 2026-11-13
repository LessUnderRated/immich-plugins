import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart' hide AssetType;
import 'package:uuid/uuid.dart';

class PrivateItem {
  final String id;
  final String file;
  final String? thumb;
  final String name;
  final String? relativePath;
  final bool isVideo;
  final DateTime createdAt;
  final double? latitude;
  final double? longitude;

  const PrivateItem({
    required this.id,
    required this.file,
    required this.thumb,
    required this.name,
    required this.relativePath,
    required this.isVideo,
    required this.createdAt,
    this.latitude,
    this.longitude,
  });

  factory PrivateItem.fromJson(Map<String, dynamic> json) => PrivateItem(
    id: json['id'] as String,
    file: json['file'] as String,
    thumb: json['thumb'] as String?,
    name: json['name'] as String? ?? 'item',
    relativePath: json['relativePath'] as String?,
    isVideo: json['isVideo'] == true,
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int? ?? 0),
    latitude: (json['latitude'] as num?)?.toDouble(),
    longitude: (json['longitude'] as num?)?.toDouble(),
  );

  PrivateItem withRelativePath(String? path) => PrivateItem(
    id: id,
    file: file,
    thumb: thumb,
    name: name,
    relativePath: path,
    isVideo: isVideo,
    createdAt: createdAt,
    latitude: latitude,
    longitude: longitude,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'file': file,
    'thumb': thumb,
    'name': name,
    'relativePath': relativePath,
    'isVideo': isVideo,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'latitude': latitude,
    'longitude': longitude,
  };
}

class PrivateVaultRepository {
  const PrivateVaultRepository();

  Future<Directory> _dir() async {
    final directory = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'private'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> _index() async => File(p.join((await _dir()).path, 'index.json'));

  Future<List<PrivateItem>> list() async {
    final index = await _index();
    if (!index.existsSync()) {
      return [];
    }
    try {
      final items = (jsonDecode(await index.readAsString()) as List)
          .whereType<Map>()
          .map((item) => PrivateItem.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      return items..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<PrivateItem> items) async {
    final index = await _index();
    final temp = File('${index.path}.tmp');
    await temp.writeAsString(jsonEncode(items.map((item) => item.toJson()).toList()), flush: true);
    await temp.rename(index.path);
  }

  Future<String> path(String fileName) async => p.join((await _dir()).path, fileName);

  static const _channel = MethodChannel('immich/device_media');
  static const _batchSize = 40;

  /// Copies device assets into app storage and deletes them from the gallery; runs as `private.hide`
  /// (`mode: "vault"`). Returns how many were hidden.
  Future<int> hide(List<LocalAsset> assets, {void Function(int done, int total)? onProgress}) => PluginHooks.run<int>(
    DataHooks.privateHide,
    () => {
      'ids': [for (final asset in assets) asset.id],
      'mode': 'vault',
    },
    () => _hide(assets, onProgress: onProgress),
    withArgs: (args) {
      final ids = PluginArgs.strings(args['ids']).toSet();
      return _hide(assets.where((asset) => ids.contains(asset.id)).toList(), onProgress: onProgress);
    },
    encode: (hidden) => hidden,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.privateHidden,
    eventData: (args, hidden) => {...args, 'hidden': hidden},
  );

  Future<int> _hide(List<LocalAsset> assets, {void Function(int done, int total)? onProgress}) async {
    final directory = await _dir();
    final copied = <String, PrivateItem>{};
    var done = 0;
    onProgress?.call(0, assets.length);

    for (var start = 0; start < assets.length; start += _batchSize) {
      final batch = assets.sublist(start, (start + _batchSize).clamp(0, assets.length));
      final planned = <String, PrivateItem>{};
      final items = <Map<String, Object?>>[];
      for (final asset in batch) {
        final id = const Uuid().v4();
        final fileName = '$id${p.extension(asset.name).toLowerCase()}';
        final thumbName = '$id.thumb.jpg';
        planned[asset.id] = PrivateItem(
          id: id,
          file: fileName,
          thumb: thumbName,
          name: asset.name,
          relativePath: null,
          isVideo: asset.type == AssetType.video,
          createdAt: asset.createdAt,
          latitude: asset.latitude,
          longitude: asset.longitude,
        );
        items.add({
          'id': asset.id,
          'video': asset.type == AssetType.video,
          'dest': p.join(directory.path, fileName),
          'thumb': p.join(directory.path, thumbName),
        });
      }

      final exported = {
        for (final row in await _channel.invokeListMethod<Map>('exportToFiles', {'items': items}) ?? const <Map>[])
          '${row['id']}': row['relativePath'] as String?,
      };
      for (final entry in planned.entries) {
        if (exported.containsKey(entry.key)) {
          copied[entry.key] = entry.value.withRelativePath(exported[entry.key]);
        }
      }
      done += batch.length;
      onProgress?.call(done, assets.length);
    }

    if (copied.isEmpty) {
      return 0;
    }

    final deleted = (await PhotoManager.editor.deleteWithIds(copied.keys.toList())).toSet();
    final kept = <PrivateItem>[];
    for (final entry in copied.entries) {
      if (deleted.contains(entry.key)) {
        kept.add(entry.value);
      } else {
        await _deleteFiles(entry.value);
      }
    }
    await _save([...await list(), ...kept]);
    return kept.length;
  }

  /// Saves the item back into the gallery and removes it from the vault; runs as `private.unhide`.
  Future<void> restore(PrivateItem item) => PluginHooks.run<void>(
    DataHooks.privateUnhide,
    () => {
      'files': [item.toJson()],
      'mode': 'vault',
    },
    () => _restore(item),
    event: DataEvents.privateUnhidden,
  );

  Future<void> _restore(PrivateItem item) async {
    final file = File(await path(item.file));
    final relativePath = Platform.isAndroid ? (item.relativePath ?? 'Pictures/Restored') : null;
    final title = p.basenameWithoutExtension(item.name);
    if (item.isVideo) {
      await PhotoManager.editor.saveVideo(
        file,
        title: item.name,
        relativePath: relativePath,
        creationDate: item.createdAt,
        latitude: item.latitude,
        longitude: item.longitude,
      );
    } else {
      await PhotoManager.editor.saveImageWithPath(
        file.path,
        title: title,
        relativePath: relativePath,
        creationDate: item.createdAt,
        latitude: item.latitude,
        longitude: item.longitude,
      );
    }
    await _delete(item);
  }

  /// Deletes the item for good; runs as `private.delete`.
  Future<void> delete(PrivateItem item) => PluginHooks.run<void>(
    DataHooks.privateDelete,
    () => {
      'files': [item.toJson()],
      'mode': 'vault',
    },
    () => _delete(item),
    event: DataEvents.privateDeleted,
  );

  Future<void> _delete(PrivateItem item) async {
    await _deleteFiles(item);
    await _save((await list()).where((existing) => existing.id != item.id).toList());
  }

  Future<void> _deleteFiles(PrivateItem item) async {
    for (final name in [item.file, ?item.thumb]) {
      final file = File(await path(name));
      if (file.existsSync()) {
        await file.delete();
      }
    }
  }
}
