import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/repositories/device_edit.repository.dart';
import 'package:immich_mobile/utils/asset_edit_renderer.utils.dart' show RenderFormat;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart' hide AssetType;

/// How a media write ended.
enum MediaWriteOutcome {
  /// A new item was added to the gallery.
  saved,

  /// The item was overwritten in place; its original is kept and [MediaWriter.restoreOriginal] brings it back.
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

  /// The asset that now holds the result: the new item for [MediaWriteOutcome.saved] and
  /// [MediaWriteOutcome.savedCopy], otherwise the asset that was replaced or restored.
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

/// Writes photos and videos into the device gallery, for the editor (save as copy, replace) and for plugins
/// (`media.saveImage`, `media.saveVideo`, `media.replace`, `media.restoreOriginal`).
///
/// * New items go to `Pictures/<folder>/` (photos) or `Movies/<folder>/` (videos) unless the folder already starts
///   with a standard root such as `DCIM/`. Saves run as `media.save` and emit `media.saved`.
/// * Replacing a device photo goes through [DeviceEditRepository.replaceBase]: the original stays backed up and the
///   result becomes the base for later edits, so the editor and plugins never undo each other. A photo in a format
///   that cannot be written in place (HEIC, WebP, ...) gets the result as a copy next to it. Videos are overwritten
///   with the native `overwriteMedia` method and their original is kept the same way. Runs as `media.replace`, emits
///   `media.replaced`.
/// * Every item this writer creates is announced on [created], so device workflows can skip the app's own output.
///
/// Native side (channel `immich/device_media`): `overwriteImage` (exists, used by the edit repository) and
/// `overwriteMedia { id, sourcePath, video }` (videos; answers true, throws `write_denied` / `write_failed`).
class MediaWriter {
  static const _channel = MethodChannel('immich/device_media');
  static const _roots = ['DCIM/', 'Pictures/', 'Movies/', 'Music/', 'Download/', 'Documents/', 'Audiobooks/'];
  static const copyFolder = 'Gallery Edits';

  static final _created = StreamController<String>.broadcast(sync: true);

  /// Ids of gallery items created by any [MediaWriter] (copies, saves).
  static Stream<String> get created => _created.stream;

  static void announceCreated(String id) => _created.add(id);

  final DeviceEditRepository _edits;
  final Future<LocalAsset?> Function(String id) _resolveAsset;

  /// Called after the gallery changed (e.g. to rescan the device library so the new item shows up).
  final Future<void> Function()? onLibraryChanged;

  const MediaWriter(this._edits, this._resolveAsset, {this.onLibraryChanged});

  static String relativePath(String? folder, {required bool video}) {
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

  static bool _isPng(Uint8List bytes) => bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50;

  static bool _isJpeg(Uint8List bytes) => bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;

  /// The extension for [mimeType], or one guessed from the first bytes of [bytes].
  static String _extension(String? mimeType, Uint8List? bytes, {required bool video}) {
    final known = _extensions[mimeType?.toLowerCase()];
    if (known != null) {
      return known;
    }
    if (bytes != null && bytes.length > 12) {
      if (_isPng(bytes)) {
        return '.png';
      }
      if (_isJpeg(bytes)) {
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

  // ---- new items -----------------------------------------------------------------------------------------------

  /// Saves the file at [path] as a new photo or video next to [source] (its date and location are copied), named
  /// [name] in [folder] (default `Gallery Edits`). Returns the new asset id. Runs as `media.save`.
  Future<String> saveCopy({required String path, required String name, String? folder, BaseAsset? source}) async {
    final local = source is LocalAsset ? source : null;
    final video = source?.type == AssetType.video || (_mimeOf(path)?.startsWith('video/') ?? false);
    final result = video
        ? await saveVideo(
            path: path,
            folder: folder ?? copyFolder,
            name: name,
            createdAt: source?.createdAt,
            latitude: local?.latitude,
            longitude: local?.longitude,
          )
        : await saveImage(
            path: path,
            folder: folder ?? copyFolder,
            name: name,
            createdAt: source?.createdAt,
            latitude: local?.latitude,
            longitude: local?.longitude,
          );
    final id = result.createdId ?? result.assetId;
    if (id == null) {
      throw const MediaWriteException(500, 'The gallery did not return the new item');
    }
    return id;
  }

  static String? _mimeOf(String path) => switch (p.extension(path).toLowerCase()) {
    '.mp4' || '.m4v' => 'video/mp4',
    '.mov' => 'video/quicktime',
    '.webm' => 'video/webm',
    '.mkv' => 'video/x-matroska',
    '.3gp' => 'video/3gpp',
    _ => null,
  };

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
    final relative = Platform.isAndroid ? relativePath(folder, video: false) : null;
    final AssetEntity entity;
    if (bytes != null) {
      final fileName = _fileName(name, _extension(mimeType, bytes, video: false));
      entity = await PhotoManager.editor.saveImage(
        bytes,
        filename: fileName,
        title: p.basenameWithoutExtension(fileName),
        desc: description,
        relativePath: relative,
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
        relativePath: relative,
        latitude: latitude,
        longitude: longitude,
        creationDate: createdAt,
      );
    }
    return _createdItem(entity.id);
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
      relativePath: Platform.isAndroid ? relativePath(folder, video: true) : null,
      latitude: latitude,
      longitude: longitude,
      creationDate: createdAt,
    );
    return _createdItem(entity.id);
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

  Future<MediaWriteResult> _createdItem(String id) async {
    _created.add(id);
    await onLibraryChanged?.call();
    return MediaWriteResult(MediaWriteOutcome.saved, assetId: id, createdId: id);
  }

  // ---- replacing ----------------------------------------------------------------------------------------------

  /// Replaces the content of the device asset [assetId] with [bytes] or the file at [path]; [width] and [height]
  /// (when known) update the stored pixel size. The original is always kept and [restoreOriginal] brings it back.
  Future<MediaWriteResult> replace(String assetId, {Uint8List? bytes, String? path, int? width, int? height}) {
    if ((bytes == null) == (path == null)) {
      throw const MediaWriteException(400, 'Give either bytes or a file path');
    }
    return PluginHooks.run<MediaWriteResult>(
      DataHooks.mediaReplace,
      () => {'assetId': assetId, 'path': path, 'size': bytes?.length, 'width': width, 'height': height},
      () => _replace(assetId, bytes, path, width, height),
      withArgs: (args) => _replace(
        assetId,
        bytes,
        PluginArgs.string(args['path']) ?? path,
        PluginArgs.integer(args['width']) ?? width,
        PluginArgs.integer(args['height']) ?? height,
      ),
      encode: (result) => result.toJson(),
      decode: MediaWriteResult.fromJson,
      event: DataEvents.mediaReplaced,
      eventData: (args, result) => {...args, ...result.toJson()},
    );
  }

  Future<MediaWriteResult> _replace(String assetId, Uint8List? bytes, String? path, int? width, int? height) async {
    final asset = await _resolveAsset(assetId);
    if (asset == null) {
      throw MediaWriteException(404, 'Asset $assetId is not on this device');
    }
    if (asset.type == AssetType.video) {
      return _replaceVideo(asset, path ?? await _temp(asset.id, bytes!));
    }

    final format = _edits.replaceFormat(asset);
    if (format == null) {
      // HEIC, WebP and other formats cannot be written in place: keep the original and save the result next to it.
      final source = path ?? await _temp(asset.id, bytes!, extension: _extension(null, bytes, video: false));
      final id = await saveCopy(
        path: source,
        name: '${p.basenameWithoutExtension(asset.name)}_edited${p.extension(source)}',
        source: asset,
      );
      return MediaWriteResult(MediaWriteOutcome.savedCopy, assetId: id, createdId: id);
    }

    final data = bytes ?? await File(path!).readAsBytes();
    final encoded = await _encodeAs(data, format);
    final size = _imageSize(encoded) ?? (width != null && height != null ? (width, height) : null);
    final file = File(p.join((await getTemporaryDirectory()).path, 'media_replace_${asset.id}${p.extension(asset.name)}'));
    await file.writeAsBytes(encoded, flush: true);
    try {
      await _edits.replaceBase(asset, file, width: size?.$1, height: size?.$2);
    } finally {
      if (file.existsSync()) {
        await file.delete();
      }
    }
    await onLibraryChanged?.call();
    return MediaWriteResult(MediaWriteOutcome.replaced, assetId: asset.id);
  }

  /// [data] in [format], re-encoded (off the UI isolate) when it is in another format.
  static Future<Uint8List> _encodeAs(Uint8List data, RenderFormat format) async {
    final matches = switch (format) {
      RenderFormat.jpeg => _isJpeg(data),
      RenderFormat.png => _isPng(data),
    };
    if (matches) {
      return data;
    }
    return Isolate.run(() {
      final image = img.decodeImage(data);
      if (image == null) {
        throw const MediaWriteException(415, 'The replacement is not an image the app can read');
      }
      return switch (format) {
        RenderFormat.jpeg => img.encodeJpg(image, quality: 95),
        RenderFormat.png => img.encodePng(image),
      };
    });
  }

  /// Pixel size from a PNG or JPEG header, without decoding the image.
  static (int, int)? _imageSize(Uint8List bytes) {
    if (_isPng(bytes) && bytes.length >= 24) {
      final data = ByteData.sublistView(bytes);
      return (data.getUint32(16), data.getUint32(20));
    }
    if (!_isJpeg(bytes)) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    var offset = 2;
    while (offset + 9 < bytes.length) {
      if (bytes[offset] != 0xFF) {
        offset++;
        continue;
      }
      final marker = bytes[offset + 1];
      final length = data.getUint16(offset + 2);
      final isFrame = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
      if (isFrame) {
        return (data.getUint16(offset + 7), data.getUint16(offset + 5));
      }
      offset += 2 + length;
    }
    return null;
  }

  Future<File> _videoBackup(LocalAsset asset) async {
    final directory = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'media_originals'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, '${asset.id}${p.extension(asset.name).toLowerCase()}'));
  }

  Future<MediaWriteResult> _replaceVideo(LocalAsset asset, String source) async {
    final backup = await _videoBackup(asset);
    if (!backup.existsSync()) {
      final original = await (await AssetEntity.fromId(asset.id))?.originFile;
      if (original == null || !original.existsSync()) {
        throw const MediaWriteException(404, 'Original video file not found');
      }
      await original.copy(backup.path);
    }
    await _overwriteVideo(asset.id, source);
    await onLibraryChanged?.call();
    return MediaWriteResult(MediaWriteOutcome.replaced, assetId: asset.id);
  }

  static Future<void> _overwriteVideo(String id, String source) async {
    try {
      await _channel.invokeMethod<bool>('overwriteMedia', {'id': id, 'sourcePath': source, 'video': true});
    } on MissingPluginException {
      throw const MediaWriteException(501, 'Replacing videos needs a newer app build');
    } on PlatformException catch (error) {
      throw MediaWriteException(error.code == 'write_denied' ? 403 : 500, error.message ?? error.code);
    }
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  /// Puts back the original of an asset replaced through [replace] or the editor (also drops editor edits).
  /// Emits `media.restored`.
  Future<MediaWriteResult> restoreOriginal(String assetId) async {
    final asset = await _resolveAsset(assetId);
    if (asset == null) {
      throw MediaWriteException(404, 'Asset $assetId is not on this device');
    }
    var restored = false;
    if (asset.type == AssetType.video) {
      final backup = await _videoBackup(asset);
      if (backup.existsSync()) {
        await _overwriteVideo(asset.id, backup.path);
        await backup.delete();
        restored = true;
      }
    } else {
      restored = (await _edits.removeEdits(asset)).outcome == DeviceEditOutcome.restored;
    }
    if (restored) {
      await onLibraryChanged?.call();
      PluginHooks.emit(DataEvents.mediaRestored, () => {'assetId': assetId});
    }
    return MediaWriteResult(restored ? MediaWriteOutcome.restored : MediaWriteOutcome.unchanged, assetId: assetId);
  }

  static Future<String> _temp(String assetId, Uint8List bytes, {String extension = ''}) async {
    final file = File(p.join((await getTemporaryDirectory()).path, 'media_replace_$assetId$extension'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
