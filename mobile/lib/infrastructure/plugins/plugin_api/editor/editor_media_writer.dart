import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/media_writer.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_workspace.dart';
import 'package:immich_mobile/infrastructure/repositories/device_edit.repository.dart';
import 'package:immich_mobile/utils/asset_edit_renderer.utils.dart';

/// Where a baked editor result goes. The editor asks every time.
enum EditorSaveTarget {
  /// A new photo next to the original (`media.saveImage`).
  copy,

  /// The original's file is replaced; the original stays backed up (`media.replace`).
  replace;

  static EditorSaveTarget? parse(Object? value) => values.where((target) => target.name == value).firstOrNull;
}

class EditorSaveResult {
  final EditorSaveTarget? target;

  /// The edited asset, or the new copy's local id.
  final String? assetId;
  final String? createdId;

  const EditorSaveResult({this.target, this.assetId, this.createdId});

  Map<String, dynamic> toJson() => {
    'target': target?.name ?? 'edits',
    if (assetId != null) 'assetId': assetId,
    if (createdId != null) 'createdId': createdId,
  };
}

/// Writes baked editor results to the device's media library.
abstract interface class EditorMediaWriter {
  /// Encoding [image] must have for [target], or null when [target] is not possible for [asset].
  RenderFormat? formatFor(BaseAsset? asset, EditorSaveTarget target, EditorWorkingImage image);

  /// Writes [image] (already encoded as [formatFor] returned) for [target].
  Future<EditorSaveResult> save(BaseAsset? asset, EditorSaveTarget target, EditorWorkingImage image);
}

/// [EditorMediaWriter] on top of [DeviceEditRepository]: copies go to `Pictures/Gallery Edits`, replacements keep the
/// original backed up and become the base for later non-destructive edits.
class DeviceEditMediaWriter implements EditorMediaWriter {
  final DeviceEditRepository _repository;

  const DeviceEditMediaWriter(this._repository);

  @override
  RenderFormat? formatFor(BaseAsset? asset, EditorSaveTarget target, EditorWorkingImage image) => switch (target) {
    EditorSaveTarget.copy => asset == null ? null : image.renderFormat,
    EditorSaveTarget.replace => asset is LocalAsset ? _repository.replaceFormat(asset) : null,
  };

  @override
  Future<EditorSaveResult> save(BaseAsset? asset, EditorSaveTarget target, EditorWorkingImage image) async {
    if (asset == null) {
      throw StateError('The editor has no asset to save');
    }
    switch (target) {
      case EditorSaveTarget.copy:
        final createdId = await _repository.saveCopy(asset, await image.file.readAsBytes(), extension: image.extension);
        return EditorSaveResult(target: target, assetId: asset.id, createdId: createdId);
      case EditorSaveTarget.replace:
        if (asset is! LocalAsset) {
          throw StateError('Only photos on this device can be replaced');
        }
        await _repository.replaceBase(asset, image.file, width: image.width, height: image.height);
        return EditorSaveResult(target: target, assetId: asset.id);
    }
  }
}

/// [EditorMediaWriter] on the app's shared media writer (`media.saveImage`): new copies are announced on
/// [MediaWriter.created] so device workflows skip them; replacements go through [DeviceEditRepository.replaceBase]
/// like [DeviceEditMediaWriter], keeping the original backed up and making the result the base for later edits.
class SharedEditorMediaWriter implements EditorMediaWriter {
  final MediaWriter _writer;
  final DeviceEditMediaWriter _device;

  SharedEditorMediaWriter(this._writer, DeviceEditRepository repository) : _device = DeviceEditMediaWriter(repository);

  @override
  RenderFormat? formatFor(BaseAsset? asset, EditorSaveTarget target, EditorWorkingImage image) =>
      _device.formatFor(asset, target, image);

  @override
  Future<EditorSaveResult> save(BaseAsset? asset, EditorSaveTarget target, EditorWorkingImage image) async {
    if (asset == null || target != EditorSaveTarget.copy) {
      return _device.save(asset, target, image);
    }
    final dot = asset.name.lastIndexOf('.');
    final stem = dot > 0 ? asset.name.substring(0, dot) : asset.name;
    final createdId = await _writer.saveCopy(
      path: image.file.path,
      name: '${stem}_edited.${image.extension}',
      source: asset,
    );
    return EditorSaveResult(target: target, assetId: asset.id, createdId: createdId);
  }
}
