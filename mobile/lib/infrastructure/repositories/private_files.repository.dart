import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const privateAssetIdPrefix = 'private:';

const _plausibleDateFloor = 86400000 * 365;

final _nameDatePattern = RegExp(r'((?:19|20)\d{2})-?(\d{2})-?(\d{2})(?:[ _.\-T]?(\d{2})[.\-:]?(\d{2})[.\-:]?(\d{2}))?');

DateTime? privateDateFromName(String name) {
  for (final match in _nameDatePattern.allMatches(name)) {
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) {
      continue;
    }
    final hour = int.tryParse(match.group(4) ?? '') ?? 0;
    final minute = int.tryParse(match.group(5) ?? '') ?? 0;
    final second = int.tryParse(match.group(6) ?? '') ?? 0;
    if (hour > 23 || minute > 59 || second > 59) {
      return DateTime(year, month, day);
    }
    return DateTime(year, month, day, hour, minute, second);
  }
  final millis = RegExp(r'(1[3-9]\d{11})').firstMatch(name)?.group(1);
  return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(int.parse(millis));
}

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
  final bool isFavorite;

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
    this.isFavorite = false,
  });

  PrivateFile copyWith({DateTime? takenAt, bool? isFavorite}) => PrivateFile(
    file: file,
    thumb: thumb,
    originalPath: originalPath,
    name: name,
    mime: mime,
    takenAt: takenAt ?? this.takenAt,
    width: width,
    height: height,
    durationMs: durationMs,
    isVideo: isVideo,
    isFavorite: isFavorite ?? this.isFavorite,
  );

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
    isFavorite: json['favorite'] == true,
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
    isFavorite: isFavorite,
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
    'favorite': isFavorite,
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
          .map(_withFallbackDate)
          .toList();
      return files..sort((a, b) => b.takenAt.compareTo(a.takenAt));
    } catch (_) {
      return [];
    }
  }

  PrivateFile _withFallbackDate(PrivateFile entry) {
    if (entry.takenAt.millisecondsSinceEpoch > _plausibleDateFloor) {
      return entry;
    }
    final modified = File(entry.file).lastModifiedSync();
    final takenAt =
        privateDateFromName(entry.name) ??
        (modified.millisecondsSinceEpoch > _plausibleDateFloor ? modified : entry.takenAt);
    return entry.copyWith(takenAt: takenAt);
  }

  Future<void> addCopy(
    String sourceAssetId, {
    required String file,
    required String name,
    required String mime,
    required int width,
    required int height,
  }) async {
    final files = await list();
    final source = files.where((entry) => entry.assetId == sourceAssetId).firstOrNull;
    if (source == null) {
      return;
    }
    await _save([
      ...files,
      PrivateFile(
        file: file,
        thumb: null,
        originalPath: p.join(p.dirname(source.originalPath), name),
        name: name,
        mime: mime,
        takenAt: source.takenAt,
        width: width,
        height: height,
        durationMs: null,
        isVideo: false,
        isFavorite: source.isFavorite,
      ),
    ]);
  }

  Future<void> setFavorite(Iterable<String> paths, bool favorite) async {
    final targets = paths.toSet();
    await _save([
      for (final entry in await list()) targets.contains(entry.file) ? entry.copyWith(isFavorite: favorite) : entry,
    ]);
  }

  Future<void> _save(List<PrivateFile> files) async {
    final index = await _index();
    final temp = File('${index.path}.tmp');
    await temp.writeAsString(jsonEncode(files.map((file) => file.toJson()).toList()), flush: true);
    await temp.rename(index.path);
    _changes.add(null);
  }

  /// Hides device assets from every app; runs as `private.hide`. Returns the ids of the assets that were hidden.
  Future<List<String>> hide(List<LocalAsset> assets) => PluginHooks.run<List<String>>(
    DataHooks.privateHide,
    () => {
      'ids': [for (final asset in assets) asset.id],
      'mode': 'files',
    },
    () => _hide(assets),
    withArgs: (args) {
      final ids = PluginArgs.strings(args['ids']).toSet();
      return _hide(assets.where((asset) => ids.contains(asset.id)).toList());
    },
    encode: (ids) => ids,
    decode: PluginArgs.strings,
    event: DataEvents.privateHidden,
    eventData: (args, hidden) => {'ids': hidden, 'mode': 'files'},
  );

  Future<List<String>> _hide(List<LocalAsset> assets) async {
    if (assets.isEmpty) {
      return const [];
    }
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

  /// Puts hidden files back into the gallery; runs as `private.unhide`. Returns how many were restored.
  Future<int> unhide(List<PrivateFile> files) => PluginHooks.run<int>(
    DataHooks.privateUnhide,
    () => {
      'files': [for (final file in files) file.toJson()],
      'mode': 'files',
    },
    () => _unhide(files),
    withArgs: (args) => _unhide(_select(files, args['files'])),
    encode: (restored) => restored,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.privateUnhidden,
    eventData: (args, restored) => {...args, 'restored': restored},
  );

  Future<int> _unhide(List<PrivateFile> files) async {
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

  /// Deletes hidden files for good; runs as `private.delete`.
  Future<void> delete(List<PrivateFile> files) => PluginHooks.run<void>(
    DataHooks.privateDelete,
    () => {
      'files': [for (final file in files) file.toJson()],
      'mode': 'files',
    },
    () => _delete(files),
    withArgs: (args) => _delete(_select(files, args['files'])),
    event: DataEvents.privateDeleted,
  );

  Future<void> _delete(List<PrivateFile> files) async {
    final paths = {for (final file in files) file.file};
    for (final path in paths) {
      await _channel.invokeMethod('privateDelete', {'file': path});
    }
    await _save((await list()).where((entry) => !paths.contains(entry.file)).toList());
  }

  /// The files of [files] that a plugin kept in its changed `files` argument (by `file` path).
  static List<PrivateFile> _select(List<PrivateFile> files, Object? json) {
    final kept = {
      for (final entry in json is List ? json : const []) entry is Map ? '${entry['file']}' : '$entry',
    };
    return files.where((file) => kept.contains(file.file)).toList();
  }
}
