import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
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

  Future<int> moveTo(List<LocalAsset> assets, String relativePath) async {
    final moved = await _channel.invokeMethod<int>('moveToFolder', {
      'items': [
        for (final asset in assets) {'id': asset.id, 'video': asset.type == AssetType.video},
      ],
      'relativePath': relativePath,
    });
    return moved ?? 0;
  }

  Future<void> setFavorite(List<LocalAsset> assets, bool favorite) async {
    for (final asset in assets) {
      final entity = await AssetEntity.fromId(asset.id);
      if (entity == null) {
        continue;
      }
      Platform.isAndroid
          ? await PhotoManager.editor.android.favoriteAsset(entity: entity, favorite: favorite)
          : await PhotoManager.editor.darwin.favoriteAsset(entity: entity, favorite: favorite);
    }
  }
}
