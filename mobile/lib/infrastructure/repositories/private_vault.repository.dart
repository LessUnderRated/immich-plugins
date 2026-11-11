import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
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

  Future<int> hide(List<LocalAsset> assets) async {
    final directory = await _dir();
    final copied = <String, PrivateItem>{};
    for (final asset in assets) {
      final entity = await AssetEntity.fromId(asset.id);
      final source = await entity?.originFile;
      if (entity == null || source == null || !source.existsSync()) {
        continue;
      }
      final id = const Uuid().v4();
      final fileName = '$id${p.extension(asset.name).toLowerCase()}';
      await source.copy(p.join(directory.path, fileName));

      String? thumbName;
      final thumb = await entity.thumbnailDataWithSize(const ThumbnailSize.square(320), quality: 85);
      if (thumb != null) {
        thumbName = '$id.thumb.jpg';
        await File(p.join(directory.path, thumbName)).writeAsBytes(thumb, flush: true);
      }

      copied[asset.id] = PrivateItem(
        id: id,
        file: fileName,
        thumb: thumbName,
        name: asset.name,
        relativePath: entity.relativePath,
        isVideo: asset.type == AssetType.video,
        createdAt: asset.createdAt,
        latitude: asset.latitude,
        longitude: asset.longitude,
      );
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

  Future<void> restore(PrivateItem item) async {
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
    await delete(item);
  }

  Future<void> delete(PrivateItem item) async {
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
