import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/infrastructure/repositories/private_files.repository.dart';
import 'package:immich_mobile/utils/asset_edit_renderer.utils.dart';
import 'package:openapi/api.dart' show CropParameters, MirrorParameters, MosaicParameters, RotateParameters;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

enum DeviceEditOutcome { editedInPlace, savedCopy, restored, unchanged }

typedef DeviceEditResult = ({DeviceEditOutcome outcome, String? createdId});

typedef DeviceEditCopy = ({String id, String name, String mime, int width, int height});

const _inPlaceFormats = {'.jpg': RenderFormat.jpeg, '.jpeg': RenderFormat.jpeg, '.png': RenderFormat.png};

class DeviceEditRepository {
  static const _channel = MethodChannel('immich/device_media');

  final CensorEffectBuilder? censorEffects;

  const DeviceEditRepository({this.censorEffects});

  Future<Directory> _editsDir() async {
    final directory = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'edits'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> _stateFile() async => File(p.join((await _editsDir()).path, 'edits.json'));

  Future<Map<String, dynamic>> _readState() async {
    final file = await _stateFile();
    if (!file.existsSync()) {
      return {};
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeState(Map<String, dynamic> state) async {
    final file = await _stateFile();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(state), flush: true);
    await temp.rename(file.path);
  }

  Future<File> _backupFile(String localId, String name) async =>
      File(p.join((await _editsDir()).path, 'originals', '$localId${p.extension(name).toLowerCase()}'));

  Future<File?> _backupIfExists(String localId) async {
    final directory = Directory(p.join((await _editsDir()).path, 'originals'));
    if (!directory.existsSync()) {
      return null;
    }
    for (final file in directory.listSync().whereType<File>()) {
      if (p.basenameWithoutExtension(file.path) == localId) {
        return file;
      }
    }
    return null;
  }

  Future<Uint8List?> readOriginal(String localId) async {
    final backup = await _backupIfExists(_backupKey(localId));
    if (backup != null) {
      return backup.readAsBytes();
    }
    final file = await _sourceFile(localId);
    if (file == null || !file.existsSync()) {
      return null;
    }
    return file.readAsBytes();
  }

  Future<List<Map<String, dynamic>>> getEditsJson(String localId) async {
    final edits = (await _readState())[localId];
    return edits is List ? edits.whereType<Map>().map(Map<String, dynamic>.from).toList() : const [];
  }

  Future<List<AssetEdit>> getEdits(String localId) async =>
      (await getEditsJson(localId)).map(assetEditFromJson).nonNulls.toList();

  bool supportsInPlace(LocalAsset asset) =>
      Platform.isAndroid && _inPlaceFormats.containsKey(p.extension(asset.name).toLowerCase());

  Future<DeviceEditResult> applyEdits(LocalAsset asset, List<AssetEdit> edits) async {
    if (edits.isEmpty) {
      return removeEdits(asset);
    }

    if (!supportsInPlace(asset)) {
      final original = await readOriginal(asset.id);
      if (original == null) {
        throw StateError('Original file not found');
      }
      final rendered = await renderAssetEdits(original, edits, censorEffects: censorEffects);
      return (outcome: DeviceEditOutcome.savedCopy, createdId: await _saveCopy(asset, rendered.bytes));
    }

    final backup = await _ensureBackup(asset);
    final rendered = await renderAssetEdits(
      await backup.readAsBytes(),
      edits,
      format: _inPlaceFormats[p.extension(asset.name).toLowerCase()]!,
      censorEffects: censorEffects,
    );
    await _overwrite(asset.id, rendered.bytes, exifSource: backup, width: rendered.width, height: rendered.height);

    final state = await _readState();
    state[asset.id] = edits.map(assetEditToJson).toList();
    await _writeState(state);
    return (outcome: DeviceEditOutcome.editedInPlace, createdId: null);
  }

  Future<Uint8List?> readCurrent(String localId) async {
    final file = await _sourceFile(localId);
    if (file == null || !file.existsSync()) {
      return null;
    }
    return file.readAsBytes();
  }

  bool replacesAsPng(LocalAsset asset) => _inPlaceFormats[p.extension(asset.name).toLowerCase()] == RenderFormat.png;

  Future<DeviceEditResult> replaceImage(LocalAsset asset, Uint8List bytes) async {
    if (!supportsInPlace(asset)) {
      return (outcome: DeviceEditOutcome.savedCopy, createdId: await _saveCopy(asset, bytes));
    }

    final backup = await _ensureBackup(asset);
    await _overwrite(asset.id, bytes, exifSource: backup);
    return (outcome: DeviceEditOutcome.editedInPlace, createdId: null);
  }

  Future<File?> _sourceFile(String localId) async {
    if (isPrivateAssetId(localId)) {
      return File(privateFilePathOf(localId));
    }
    final entity = await AssetEntity.fromId(localId);
    return entity?.originFile;
  }

  String _backupKey(String localId) =>
      isPrivateAssetId(localId) ? 'private_${p.basename(privateFilePathOf(localId)).hashCode.toUnsigned(32)}' : localId;

  Future<bool> hasOriginal(String localId) async => await _backupIfExists(_backupKey(localId)) != null;

  Future<DeviceEditCopy> saveEditsAsCopy(LocalAsset asset, List<AssetEdit> edits) async {
    final original = await readOriginal(asset.id);
    if (original == null) {
      throw StateError('Original file not found');
    }
    final extension = p.extension(asset.name).toLowerCase();
    final format = _inPlaceFormats[extension] ?? RenderFormat.jpeg;
    final rendered = await renderAssetEdits(original, edits, format: format, censorEffects: censorEffects);
    final outExtension = format == RenderFormat.png ? '.png' : (extension == '.jpeg' ? '.jpeg' : '.jpg');
    final mime = format == RenderFormat.png ? 'image/png' : 'image/jpeg';
    final baseName = '${p.basenameWithoutExtension(asset.name)}_edited';
    final exifSource = await _backupIfExists(_backupKey(asset.id)) ?? await _sourceFile(asset.id);

    if (isPrivateAssetId(asset.id)) {
      final source = File(privateFilePathOf(asset.id));
      var name = '$baseName$outExtension';
      var suffix = 1;
      while (File(p.join(source.parent.path, '$name.private')).existsSync()) {
        name = '${baseName}_$suffix$outExtension';
        suffix++;
      }
      final target = File(p.join(source.parent.path, '$name.private'));
      await target.writeAsBytes(rendered.bytes, flush: true);
      if (exifSource != null && format == RenderFormat.jpeg) {
        await _copyExif(exifSource, target, rendered.width, rendered.height);
      }
      target.setLastModifiedSync(source.lastModifiedSync());
      return (id: target.path, name: name, mime: mime, width: rendered.width, height: rendered.height);
    }

    final name = '$baseName$outExtension';
    final temp = File(p.join((await getTemporaryDirectory()).path, 'copy_${asset.id}$outExtension'));
    await temp.writeAsBytes(rendered.bytes, flush: true);
    try {
      final id = await _channel.invokeMethod<String>('saveImageCopy', {
        'originalId': asset.id,
        'sourcePath': temp.path,
        'exifSourcePath': format == RenderFormat.jpeg ? exifSource?.path : null,
        'name': name,
        'mime': mime,
        'takenAt': asset.createdAt.millisecondsSinceEpoch,
        'width': rendered.width,
        'height': rendered.height,
      });
      return (id: id!, name: name, mime: mime, width: rendered.width, height: rendered.height);
    } finally {
      if (temp.existsSync()) {
        await temp.delete();
      }
    }
  }

  Future<void> _copyExif(File source, File target, int? width, int? height) => _channel.invokeMethod('copyExif', {
    'exifSourcePath': source.path,
    'targetPath': target.path,
    'width': width,
    'height': height,
  });

  Future<DeviceEditResult> removeEdits(LocalAsset asset) async {
    final backup = await _backupIfExists(_backupKey(asset.id));
    final state = await _readState();
    if (backup == null) {
      return (outcome: DeviceEditOutcome.unchanged, createdId: null);
    }
    await _overwrite(asset.id, await backup.readAsBytes());
    state.remove(asset.id);
    await _writeState(state);
    await backup.delete();
    return (outcome: DeviceEditOutcome.restored, createdId: null);
  }

  Future<File> _ensureBackup(LocalAsset asset) async {
    final existing = await _backupIfExists(_backupKey(asset.id));
    if (existing != null) {
      return existing;
    }
    final source = await _sourceFile(asset.id);
    if (source == null || !source.existsSync()) {
      throw StateError('Original file not found');
    }
    final backup = await _backupFile(_backupKey(asset.id), asset.name);
    await backup.parent.create(recursive: true);
    return source.copy(backup.path);
  }

  Future<void> _overwrite(String localId, Uint8List bytes, {File? exifSource, int? width, int? height}) async {
    if (isPrivateAssetId(localId)) {
      final target = File(privateFilePathOf(localId));
      final modified = target.lastModifiedSync();
      final staged = File('${target.path}.tmp');
      await staged.writeAsBytes(bytes, flush: true);
      await staged.rename(target.path);
      if (exifSource != null &&
          _inPlaceFormats[p.extension(privateFilePathOf(localId).replaceAll('.private', '')).toLowerCase()] ==
              RenderFormat.jpeg) {
        await _copyExif(exifSource, target, width, height);
      }
      target.setLastModifiedSync(modified);
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      return;
    }
    final temp = File(p.join((await getTemporaryDirectory()).path, 'edit_$localId'));
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await _channel.invokeMethod('overwriteImage', {
        'id': localId,
        'sourcePath': temp.path,
        'exifSourcePath': exifSource?.path,
        'width': width,
        'height': height,
      });
    } finally {
      if (temp.existsSync()) {
        await temp.delete();
      }
    }
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  Future<String?> _saveCopy(LocalAsset asset, Uint8List jpeg) async {
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

Map<String, dynamic> assetEditToJson(AssetEdit edit) => switch (edit) {
  CropEdit(:final parameters) => {'action': 'crop', 'parameters': parameters.toJson()},
  RotateEdit(:final parameters) => {'action': 'rotate', 'parameters': parameters.toJson()},
  MirrorEdit(:final parameters) => {'action': 'mirror', 'parameters': parameters.toJson()},
  MosaicEdit(:final parameters) => {'action': 'mosaic', 'parameters': parameters.toJson()},
};

AssetEdit? assetEditFromJson(Map edit) {
  final parameters = edit['parameters'];
  return switch (edit['action']) {
    'crop' => switch (CropParameters.fromJson(parameters)) {
      final value? => CropEdit(value),
      null => null,
    },
    'rotate' => switch (RotateParameters.fromJson(parameters)) {
      final value? => RotateEdit(value),
      null => null,
    },
    'mirror' => switch (MirrorParameters.fromJson(parameters)) {
      final value? => MirrorEdit(value),
      null => null,
    },
    'mosaic' => switch (MosaicParameters.fromJson(parameters)) {
      final value? => MosaicEdit(value),
      null => null,
    },
    _ => null,
  };
}
