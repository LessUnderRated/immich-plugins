import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

class DeviceEditRepository {
  const DeviceEditRepository();

  Future<Uint8List?> readOriginal(String localId) async {
    final entity = await AssetEntity.fromId(localId);
    final file = await entity?.originFile;
    if (file == null || !file.existsSync()) {
      return null;
    }
    return file.readAsBytes();
  }

  Future<String?> saveEditedCopy(LocalAsset asset, Uint8List jpeg) async {
    final baseName = p.basenameWithoutExtension(asset.name);
    final saved = await PhotoManager.editor.saveImage(
      jpeg,
      filename: '${baseName}_edited.jpg',
      title: '${baseName}_edited',
      relativePath: Platform.isAndroid ? 'Pictures/Gallery Edits' : null,
      latitude: asset.latitude,
      longitude: asset.longitude,
      creationDate: asset.createdAt,
    );
    return saved.id;
  }
}
