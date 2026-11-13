import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
