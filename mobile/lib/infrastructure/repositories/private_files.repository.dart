import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const privateAssetIdPrefix = 'private:';

bool isPrivateAssetId(String id) => id.startsWith(privateAssetIdPrefix);

String privateFilePathOf(String id) => id.substring(privateAssetIdPrefix.length);

class PrivateFile {
  final String file;
  final String? thumb;
  final String originalPath;
  final String name;
  final String? mime;
  final DateTime takenAt;
  final int? width;
  final int? height;
  final int? durationMs;
  final bool isVideo;

  const PrivateFile({
    required this.file,
    required this.thumb,
    required this.originalPath,
    required this.name,
    required this.mime,
    required this.takenAt,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.isVideo,
  });

  factory PrivateFile.fromJson(Map<String, dynamic> json) => PrivateFile(
    file: json['file'] as String,
    thumb: json['thumb'] as String?,
    originalPath: json['originalPath'] as String,
    name: json['name'] as String? ?? p.basename(json['originalPath'] as String),
    mime: json['mime'] as String?,
    takenAt: DateTime.fromMillisecondsSinceEpoch((json['takenAt'] as num?)?.toInt() ?? 0),
    width: (json['width'] as num?)?.toInt(),
    height: (json['height'] as num?)?.toInt(),
    durationMs: (json['durationMs'] as num?)?.toInt(),
    isVideo: json['video'] == true,
  );

  String get assetId => '$privateAssetIdPrefix$file';

  LocalAsset toAsset() => LocalAsset(
    id: assetId,
    name: name,
    type: isVideo ? AssetType.video : AssetType.image,
    createdAt: takenAt,
    updatedAt: takenAt,
    width: width,
    height: height,
    durationMs: durationMs,
    playbackStyle: isVideo ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
    isEdited: false,
  );

  Map<String, dynamic> toJson() => {
    'file': file,
    'thumb': thumb,
    'originalPath': originalPath,
    'name': name,
    'mime': mime,
    'takenAt': takenAt.millisecondsSinceEpoch,
    'width': width,
    'height': height,
    'durationMs': durationMs,
    'video': isVideo,
  };
}

/// Photos hidden from every app: renamed to `.private` in a .nomedia folder and removed from MediaStore.
class PrivateFilesRepository {
  static const _channel = MethodChannel('immich/device_media');

  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  void notifyChanged() => _changes.add(null);

  Future<List<PrivateFile>> forAssets(Iterable<BaseAsset> assets) async {
    final paths = {
      for (final asset in assets)
        if (asset is LocalAsset && isPrivateAssetId(asset.id)) privateFilePathOf(asset.id),
    };
    return (await list()).where((file) => paths.contains(file.file)).toList();
  }

  Future<bool> hasAccess() async =>
      Platform.isAndroid && (await _channel.invokeMethod<bool>('privateHasAccess') ?? false);

  Future<void> requestAccess() => _channel.invokeMethod('privateRequestAccess');

  Future<File> _index() async => File(p.join((await getApplicationDocumentsDirectory()).path, 'private_files.json'));

  Future<List<PrivateFile>> list() async {
    final index = await _index();
    if (!index.existsSync()) {
      return [];
    }
    try {
      final files = (jsonDecode(await index.readAsString()) as List)
          .whereType<Map>()
          .map((entry) => PrivateFile.fromJson(Map<String, dynamic>.from(entry)))
          .where((entry) => File(entry.file).existsSync())
          .toList();
      return files..sort((a, b) => b.takenAt.compareTo(a.takenAt));
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<PrivateFile> files) async {
    final index = await _index();
    final temp = File('${index.path}.tmp');
    await temp.writeAsString(jsonEncode(files.map((file) => file.toJson()).toList()), flush: true);
    await temp.rename(index.path);
    _changes.add(null);
  }

  /// Returns the ids of the assets that were hidden.
  Future<List<String>> hide(List<LocalAsset> assets) async {
    final rows = await _channel.invokeListMethod<Map>('privateHide', {
      'items': [
        for (final asset in assets) {'id': asset.id, 'video': asset.type == AssetType.video},
      ],
    });
    final hidden = [
      for (final row in rows ?? const <Map>[])
        (id: '${row['id']}', file: PrivateFile.fromJson(Map<String, dynamic>.from(row))),
    ];
    if (hidden.isNotEmpty) {
      await _save([...await list(), for (final entry in hidden) entry.file]);
    }
    return [for (final entry in hidden) entry.id];
  }

  Future<int> unhide(List<PrivateFile> files) async {
    var restored = 0;
    final remaining = await list();
    for (final file in files) {
      final path = await _channel.invokeMethod<String>('privateUnhide', {
        'file': file.file,
        'originalPath': file.originalPath,
      });
      if (path != null) {
        restored++;
        remaining.removeWhere((entry) => entry.file == file.file);
      }
    }
    await _save(remaining);
    return restored;
  }

  Future<void> delete(List<PrivateFile> files) async {
    final paths = {for (final file in files) file.file};
    for (final path in paths) {
      await _channel.invokeMethod('privateDelete', {'file': path});
    }
    await _save((await list()).where((entry) => !paths.contains(entry.file)).toList());
  }
}
