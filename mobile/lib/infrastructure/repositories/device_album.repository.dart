import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:photo_manager/photo_manager.dart' hide AssetType;

class DeviceAlbum {
  final String id;
  final String name;
  final int count;

  const DeviceAlbum({required this.id, required this.name, required this.count});
}

typedef AlbumTarget = ({String name, String relativePath});

class DeviceAlbumRepository {
  static const _channel = MethodChannel('immich/device_media');
  static const removedFolder = 'Pictures/';

  const DeviceAlbumRepository();

  Future<List<DeviceAlbum>> albums() async {
    final paths = await PhotoManager.getAssetPathList(type: RequestType.common, hasAll: false);
    final albums = [
      for (final path in paths) DeviceAlbum(id: path.id, name: path.name, count: await path.assetCountAsync),
    ];
    return albums..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  static String newAlbumPath(String name) => 'Pictures/${name.trim()}/';

  Future<String?> relativePathOf(String albumId) async {
    final path = await AssetPathEntity.fromId(albumId, type: RequestType.common);
    final first = (await path.getAssetListRange(start: 0, end: 1)).firstOrNull;
    final relative = first?.relativePath;
    if (relative == null || relative.isEmpty) {
      return null;
    }
    return relative.endsWith('/') ? relative : '$relative/';
  }

  /// Moves device assets into the folder [relativePath] (e.g. `Pictures/Trips/`); runs as `asset.move`.
  Future<int> moveTo(List<LocalAsset> assets, String relativePath) => PluginHooks.run<int>(
    DataHooks.assetMove,
    () => {
      'ids': [for (final asset in assets) asset.id],
      'relativePath': relativePath,
      'source': 'local',
    },
    () => _moveTo(assets, relativePath),
    withArgs: (args) {
      final ids = PluginArgs.strings(args['ids']).toSet();
      return _moveTo(
        assets.where((asset) => ids.contains(asset.id)).toList(),
        PluginArgs.string(args['relativePath']) ?? relativePath,
      );
    },
    encode: (moved) => moved,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.assetMoved,
    eventData: (args, moved) => {...args, 'moved': moved},
  );

  Future<int> _moveTo(List<LocalAsset> assets, String relativePath) async {
    if (assets.isEmpty) {
      return 0;
    }
    final moved = await _channel.invokeMethod<int>('moveToFolder', {
      'items': [
        for (final asset in assets) {'id': asset.id, 'video': asset.type == AssetType.video},
      ],
      'relativePath': relativePath,
    });
    return moved ?? 0;
  }

  /// Sets the device favorite flag; runs as `asset.favorite` with `source: "local"`.
  Future<void> setFavorite(List<LocalAsset> assets, bool favorite) => PluginHooks.run<void>(
    DataHooks.assetFavorite,
    () => {
      'ids': [for (final asset in assets) asset.id],
      'favorite': favorite,
      'source': 'local',
    },
    () => _setFavorite(assets, favorite),
    withArgs: (args) {
      final ids = PluginArgs.strings(args['ids']).toSet();
      return _setFavorite(
        assets.where((asset) => ids.contains(asset.id)).toList(),
        PluginArgs.boolean(args['favorite']) ?? favorite,
      );
    },
    event: DataEvents.assetFavorited,
  );

  /// Sets the device favorite flag of assets known only by id (plugins, workflows).
  Future<void> setFavoriteByIds(List<String> ids, bool favorite) async {
    final entities = [for (final id in ids) await AssetEntity.fromId(id)].nonNulls.toList();
    final byId = {for (final entity in entities) entity.id: entity};
    await PluginHooks.run<void>(
      DataHooks.assetFavorite,
      () => {'ids': ids, 'favorite': favorite, 'source': 'local'},
      () => _favoriteEntities(entities, favorite),
      withArgs: (args) => _favoriteEntities(
        [for (final id in PluginArgs.strings(args['ids'])) ?byId[id]],
        PluginArgs.boolean(args['favorite']) ?? favorite,
      ),
      event: DataEvents.assetFavorited,
    );
  }

  Future<void> _setFavorite(List<LocalAsset> assets, bool favorite) async {
    for (final asset in assets) {
      final entity = await AssetEntity.fromId(asset.id);
      if (entity == null) {
        continue;
      }
      await _favoriteEntity(entity, favorite);
    }
  }

  Future<void> _favoriteEntities(List<AssetEntity> entities, bool favorite) async {
    for (final entity in entities) {
      await _favoriteEntity(entity, favorite);
    }
  }

  Future<void> _favoriteEntity(AssetEntity entity, bool favorite) async {
    Platform.isAndroid
        ? await PhotoManager.editor.android.favoriteAsset(entity: entity, favorite: favorite)
        : await PhotoManager.editor.darwin.favoriteAsset(entity: entity, favorite: favorite);
  }
}
