import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/repositories/device_edit.repository.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart' hide AssetType;

/// How a media write ended.
enum MediaWriteOutcome {
  /// A new item was added to the gallery.
  saved,

  /// The item was overwritten in place (its original is kept for "restore original" when asked).
  replaced,

  /// The format cannot be overwritten in place, so the result was saved as a new item next to the original.
  savedCopy,

  /// The original was put back.
  restored,

  /// Nothing to do (e.g. no original to restore).
  unchanged,
}

class MediaWriteResult {
  final MediaWriteOutcome outcome;

  /// The asset that was written: the new item for [MediaWriteOutcome.saved] and [MediaWriteOutcome.savedCopy],
  /// otherwise the asset that was replaced or restored.
  final String? assetId;

  /// The new gallery item, when one was created.
  final String? createdId;

  const MediaWriteResult(this.outcome, {this.assetId, this.createdId});

  Map<String, dynamic> toJson() => {'outcome': outcome.name, 'assetId': assetId, 'createdId': createdId};

  static MediaWriteResult fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('A media write result must be an object');
    }
    return MediaWriteResult(
      MediaWriteOutcome.values.where((outcome) => outcome.name == json['outcome']).firstOrNull ??
          MediaWriteOutcome.saved,
      assetId: PluginArgs.string(json['assetId']),
      createdId: PluginArgs.string(json['createdId']),
    );
  }
}

class MediaWriteException implements Exception {
  final int status;
  final String message;

  const MediaWriteException(this.status, this.message);

  @override
  String toString() => message;
}

/// Writes photos and videos into the device gallery. Used by the editor (save as copy, replace) and by plugins
/// (`media.saveImage`, `media.saveVideo`, `media.replace`, `media.restoreOriginal`).
///
/// * Saves go to `Pictures/<folder>/` (photos) or `Movies/<folder>/` (videos) unless [folder] already starts with a
///   standard root such as `DCIM/`; they run as `media.save` and emit `media.saved`.
/// * Replacing a JPEG or PNG overwrites it in place on Android and keeps the original (restorable with
///   [restoreOriginal], the same backup the editor uses); other image formats are saved as a copy. Videos are
///   overwritten through the native `overwriteMedia` channel method. Runs as `media.replace`, emits
///   `media.replaced`.
///
/// Native side (channel `immich/device_media`): `overwriteImage { id, sourcePath, exifSourcePath?, width?, height? }`
/// (exists) and `overwriteMedia { id, sourcePath, video }` (needed for videos; answers true or throws).
class MediaWriter {
  static const _channel = MethodChannel('immich/device_media');
  static const _roots = ['DCIM/', 'Pictures/', 'Movies/', 'Music/', 'Download/', 'Documents/', 'Audiobooks/'];

  final DeviceEditRepository _edits;
  final Future<LocalAsset?> Function(String id) _resolveAsset;

  /// Called after the gallery changed (e.g. to rescan the device library so the new item shows up).
  final Future<void> Function()? onLibraryChanged;

  /// Called with every gallery item this writer creates (e.g. so workflows skip the app's own output).
  final void Function(String createdId)? onCreated;

  const MediaWriter(this._edits, this._resolveAsset, {this.onLibraryChanged, this.onCreated});

  static String _relativePath(String? folder, {required bool video}) {
    final cleaned = (folder ?? '').trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (cleaned.isEmpty) {
      return video ? 'Movies/' : 'Pictures/';
    }
    if (_roots.any((root) => '$cleaned/'.toLowerCase().startsWith(root.toLowerCase()))) {
      return '$cleaned/';
    }
    return '${video ? 'Movies' : 'Pictures'}/$cleaned/';
  }

  static const _extensions = {
    'image/jpeg': '.jpg',
    'image/jpg': '.jpg',
    'image/png': '.png',
    'image/webp': '.webp',
    'image/gif': '.gif',
    'image/heic': '.heic',
    'image/heif': '.heif',
    'image/avif': '.avif',
    'image/bmp': '.bmp',
    'video/mp4': '.mp4',
    'video/quicktime': '.mov',
    'video/webm': '.webm',
    'video/3gpp': '.3gp',
    'video/x-matroska': '.mkv',
  };

  /// The extension for [mimeType], or one guessed from the first bytes of [bytes].
  static String _extension(String? mimeType, Uint8List? bytes, {required bool video}) {
    final known = _extensions[mimeType?.toLowerCase()];
    if (known != null) {
      return known;
    }
    if (bytes != null && bytes.length > 12) {
      if (bytes[0] == 0x89 && bytes[1] == 0x50) {
        return '.png';
      }
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
        return '.jpg';
      }
      if (bytes[0] == 0x47 && bytes[1] == 0x49) {
        return '.gif';
      }
      if (String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
        return '.webp';
      }
    }
    return video ? '.mp4' : '.jpg';
  }

  static String _fileName(String? name, String extension) {
    final base = (name == null || name.trim().isEmpty)
        ? 'IMG_${DateTime.now().millisecondsSinceEpoch}'
        : p.basename(name.trim());
    return p.extension(base).isEmpty ? '$base$extension' : base;
  }

  /// Saves a photo as a new gallery item from [bytes] or the file at [path].
  Future<MediaWriteResult> saveImage({
    Uint8List? bytes,
    String? path,
    String? folder,
    String? name,
    String? mimeType,
    DateTime? createdAt,
    double? latitude,
    double? longitude,
    String? description,
  }) {
    if ((bytes == null) == (path == null)) {
      throw const MediaWriteException(400, 'Give either bytes or a file path');
    }
    return PluginHooks.run<MediaWriteResult>(
      DataHooks.mediaSave,
      () => {
        'kind': 'image',
        'folder': folder,
        'name': name,
        'mimeType': mimeType,
        'path': path,
        'size': bytes?.length,
        'createdAt': PluginArgs.iso(createdAt),
      },
      () => _saveImage(bytes, path, folder, name, mimeType, createdAt, latitude, longitude, description),
      withArgs: (args) => _saveImage(
        bytes,
        PluginArgs.string(args['path']) ?? path,
        PluginArgs.string(args['folder']),
        PluginArgs.string(args['name']),
        PluginArgs.string(args['mimeType']) ?? mimeType,
        PluginArgs.date(args['createdAt']) ?? createdAt,
        latitude,
        longitude,
        description,
      ),
      encode: (result) => result.toJson(),
      decode: MediaWriteResult.fromJson,
      event: DataEvents.mediaSaved,
      eventData: (args, result) => {...args, ...result.toJson()},
    );
  }

  Future<MediaWriteResult> _saveImage(
    Uint8List? bytes,
    String? path,
    String? folder,
    String? name,
    String? mimeType,
    DateTime? createdAt,
    double? latitude,
    double? longitude,
    String? description,
  ) async {
    final relativePath = Platform.isAndroid ? _relativePath(folder, video: false) : null;
    final AssetEntity entity;
    if (bytes != null) {
      final fileName = _fileName(name, _extension(mimeType, bytes, video: false));
      entity = await PhotoManager.editor.saveImage(
        bytes,
        filename: fileName,
        title: p.basenameWithoutExtension(fileName),
        desc: description,
        relativePath: relativePath,
        latitude: latitude,
        longitude: longitude,
        creationDate: createdAt,
      );
    } else {
      final source = File(path!);
      if (!source.existsSync()) {
        throw MediaWriteException(404, 'File not found: $path');
      }
      final fileName = _fileName(name ?? p.basename(path), _extension(mimeType, null, video: false));
      entity = await PhotoManager.editor.saveImageWithPath(
        await _named(source, fileName),
        title: fileName,
        desc: description,
        relativePath: relativePath,
        latitude: latitude,
        longitude: longitude,
        creationDate: createdAt,
      );
    }
    return _created(entity.id);
  }

  /// Saves a video file as a new gallery item.
  Future<MediaWriteResult> saveVideo({
    required String path,
    String? folder,
    String? name,
    DateTime? createdAt,
    double? latitude,
    double? longitude,
    String? description,
  }) => PluginHooks.run<MediaWriteResult>(
    DataHooks.mediaSave,
    () => {'kind': 'video', 'folder': folder, 'name': name, 'path': path, 'createdAt': PluginArgs.iso(createdAt)},
    () => _saveVideo(path, folder, name, createdAt, latitude, longitude, description),
    withArgs: (args) => _saveVideo(
      PluginArgs.string(args['path']) ?? path,
      PluginArgs.string(args['folder']),
      PluginArgs.string(args['name']),
      PluginArgs.date(args['createdAt']) ?? createdAt,
      latitude,
      longitude,
      description,
    ),
    encode: (result) => result.toJson(),
    decode: MediaWriteResult.fromJson,
    event: DataEvents.mediaSaved,
    eventData: (args, result) => {...args, ...result.toJson()},
  );

  Future<MediaWriteResult> _saveVideo(
    String path,
    String? folder,
    String? name,
    DateTime? createdAt,
    double? latitude,
    double? longitude,
    String? description,
  ) async {
    final source = File(path);
    if (!source.existsSync()) {
      throw MediaWriteException(404, 'File not found: $path');
    }
    final fileName = _fileName(name ?? p.basename(path), p.extension(path).isEmpty ? '.mp4' : p.extension(path));
    final entity = await PhotoManager.editor.saveVideo(
      File(await _named(source, fileName)),
      title: fileName,
      desc: description,
      relativePath: Platform.isAndroid ? _relativePath(folder, video: true) : null,
      latitude: latitude,
      longitude: longitude,
      creationDate: createdAt,
    );
    return _created(entity.id);
  }

  /// Gallery apps take the display name from the file, so a source whose name differs is copied to a temporary
  /// file with the wanted name first.
  static Future<String> _named(File source, String fileName) async {
    if (p.basename(source.path) == fileName) {
      return source.path;
    }
    final directory = Directory(p.join((await getTemporaryDirectory()).path, 'media_writer'));
    await directory.create(recursive: true);
    return (await source.copy(p.join(directory.path, fileName))).path;
  }

  Future<MediaWriteResult> _created(String id) async {
    onCreated?.call(id);
    await onLibraryChanged?.call();
    return MediaWriteResult(MediaWriteOutcome.saved, assetId: id, createdId: id);
  }

  /// Replaces the content of the device asset [assetId] with [bytes] or the file at [path].
  ///
  /// With [backupOriginal] (default) the first replacement keeps the original so [restoreOriginal] can bring it
  /// back; formats that cannot be written in place are saved as a copy ([MediaWriteOutcome.savedCopy]).
  Future<MediaWriteResult> replace(String assetId, {Uint8List? bytes, String? path, bool backupOriginal = true}) {
    if ((bytes == null) == (path == null)) {
      throw const MediaWriteException(400, 'Give either bytes or a file path');
    }
    return PluginHooks.run<MediaWriteResult>(
      DataHooks.mediaReplace,
      () => {'assetId': assetId, 'path': path, 'size': bytes?.length, 'backupOriginal': backupOriginal},
      () => _replace(assetId, bytes, path, backupOriginal),
      withArgs: (args) => _replace(
        assetId,
        bytes,
        PluginArgs.string(args['path']) ?? path,
        PluginArgs.boolean(args['backupOriginal']) ?? backupOriginal,
      ),
      encode: (result) => result.toJson(),
      decode: MediaWriteResult.fromJson,
      event: DataEvents.mediaReplaced,
      eventData: (args, result) => {...args, ...result.toJson()},
    );
  }

  Future<MediaWriteResult> _replace(String assetId, Uint8List? bytes, String? path, bool backupOriginal) async {
    final asset = await _resolveAsset(assetId);
    if (asset == null) {
      throw MediaWriteException(404, 'Asset $assetId is not on this device');
    }

    if (asset.type == AssetType.video) {
      final source = path ?? await _temp(assetId, bytes!);
      try {
        await _channel.invokeMethod<bool>('overwriteMedia', {'id': asset.id, 'sourcePath': source, 'video': true});
      } on MissingPluginException {
        throw const MediaWriteException(501, 'Replacing videos needs a newer app build');
      } on PlatformException catch (error) {
        if (error.code == 'notImplemented') {
          throw const MediaWriteException(501, 'Replacing videos needs a newer app build');
        }
        rethrow;
      }
      _clearImageCache();
      await onLibraryChanged?.call();
      return MediaWriteResult(MediaWriteOutcome.replaced, assetId: asset.id);
    }

    final data = bytes ?? await File(path!).readAsBytes();
    if (!backupOriginal && _edits.supportsInPlace(asset)) {
      final source = await _temp(assetId, data);
      try {
        await _channel.invokeMethod('overwriteImage', {'id': asset.id, 'sourcePath': source});
      } finally {
        await File(source).delete();
      }
      _clearImageCache();
      await onLibraryChanged?.call();
      return MediaWriteResult(MediaWriteOutcome.replaced, assetId: asset.id);
    }

    final result = await _edits.replaceImage(asset, data);
    final createdId = result.createdId;
    if (createdId != null) {
      onCreated?.call(createdId);
    }
    await onLibraryChanged?.call();
    return switch (result.outcome) {
      DeviceEditOutcome.savedCopy => MediaWriteResult(
        MediaWriteOutcome.savedCopy,
        assetId: createdId,
        createdId: createdId,
      ),
      _ => MediaWriteResult(MediaWriteOutcome.replaced, assetId: asset.id),
    };
  }

  /// Puts back the original of an asset replaced in place (also undoes editor edits). Emits `media.restored`.
  Future<MediaWriteResult> restoreOriginal(String assetId) async {
    final asset = await _resolveAsset(assetId);
    if (asset == null) {
      throw MediaWriteException(404, 'Asset $assetId is not on this device');
    }
    final result = await _edits.removeEdits(asset);
    final restored = result.outcome == DeviceEditOutcome.restored;
    if (restored) {
      await onLibraryChanged?.call();
      PluginHooks.emit(DataEvents.mediaRestored, () => {'assetId': assetId});
    }
    return MediaWriteResult(restored ? MediaWriteOutcome.restored : MediaWriteOutcome.unchanged, assetId: assetId);
  }

  static Future<String> _temp(String assetId, Uint8List bytes) async {
    final file = File(p.join((await getTemporaryDirectory()).path, 'media_replace_$assetId'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  static void _clearImageCache() => PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
}
