import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/files_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/media_writer.dart';

/// Gallery writes for plugins: `media.saveImage`, `media.saveVideo`, `media.replace`, `media.restoreOriginal`.
///
/// Image data is given as `path` (relative to the plugin folder or absolute), `bytesBase64` (an encoded image) or
/// `rgba` + `width` + `height` (raw pixels, base64; saved as PNG).
class MediaHostApi implements DataHostModule {
  final MediaWriter _writer;
  final PluginPaths _paths;

  const MediaHostApi(this._writer, this._paths);

  @override
  Map<String, DataHostFunction> get functions => {
    'media.saveImage': (plugin, args) => _guard(() => saveImage(plugin, HostArgs(args).map(0))),
    'media.saveVideo': (plugin, args) => _guard(() => saveVideo(plugin, HostArgs(args).map(0))),
    'media.replace': (plugin, args) =>
        _guard(() => replace(plugin, HostArgs(args).text(0, 'assetId'), HostArgs(args).map(1))),
    'media.restoreOriginal': (plugin, args) async =>
        _guard(() async => (await _writer.restoreOriginal(HostArgs(args).text(0, 'assetId'))).toJson()),
  };

  @override
  Map<String, String> get docs => const {
    'media.saveImage':
        '[{ path | bytesBase64 | rgba + width + height, folder?, name?, mimeType?, createdAt?, latitude?, '
        'longitude?, description? }] -> { outcome: "saved", assetId, createdId }',
    'media.saveVideo': '[{ path, folder?, name?, createdAt?, latitude?, longitude?, description? }] -> '
        '{ outcome, assetId, createdId }',
    'media.replace': '[assetId, { path | bytesBase64 | rgba + width + height, width?, height? }] -> '
        '{ outcome: "replaced" | "savedCopy", assetId, createdId? } (the original is kept)',
    'media.restoreOriginal': '[assetId] -> { outcome: "restored" | "unchanged", assetId }',
  };

  static Future<Object?> _guard(Future<Object?> Function() run) async {
    try {
      return await run();
    } on MediaWriteException catch (error) {
      throw DataHostException(error.status, error.message);
    }
  }

  /// `(bytes, path, width, height)` from the image options.
  Future<(Uint8List?, String?, int?, int?)> _image(String plugin, Map<String, dynamic> options) async {
    final path = options.text('path');
    if (path != null) {
      return (null, await _paths.resolve(plugin, path), options.integer('width'), options.integer('height'));
    }
    final encoded = options.text('bytesBase64');
    if (encoded != null) {
      return (base64Decode(encoded), null, options.integer('width'), options.integer('height'));
    }
    final rgba = options.text('rgba');
    final width = options.integer('width');
    final height = options.integer('height');
    if (rgba != null && width != null && height != null) {
      final pixels = base64Decode(rgba);
      if (pixels.length != width * height * 4) {
        throw const DataHostException.badRequest('rgba must hold width * height * 4 bytes');
      }
      final png = await Isolate.run(
        () => img.encodePng(
          img.Image.fromBytes(width: width, height: height, bytes: pixels.buffer, numChannels: 4),
        ),
      );
      return (png, null, width, height);
    }
    throw const DataHostException.badRequest('Give path, bytesBase64 or rgba with width and height');
  }

  Future<Map<String, dynamic>> saveImage(String plugin, Map<String, dynamic> options) async {
    final (bytes, path, _, _) = await _image(plugin, options);
    final result = await _writer.saveImage(
      bytes: bytes,
      path: path,
      folder: options.text('folder'),
      name: options.text('name'),
      mimeType: options.text('rgba') != null ? 'image/png' : options.text('mimeType'),
      createdAt: options.date('createdAt'),
      latitude: options.real('latitude'),
      longitude: options.real('longitude'),
      description: options.text('description'),
    );
    return result.toJson();
  }

  Future<Map<String, dynamic>> saveVideo(String plugin, Map<String, dynamic> options) async {
    final path = options.text('path');
    if (path == null) {
      throw const DataHostException.badRequest('Missing path');
    }
    final result = await _writer.saveVideo(
      path: await _paths.resolve(plugin, path),
      folder: options.text('folder'),
      name: options.text('name'),
      createdAt: options.date('createdAt'),
      latitude: options.real('latitude'),
      longitude: options.real('longitude'),
      description: options.text('description'),
    );
    return result.toJson();
  }

  Future<Map<String, dynamic>> replace(String plugin, String assetId, Map<String, dynamic> options) async {
    final (bytes, path, width, height) = await _image(plugin, options);
    final result = await _writer.replace(assetId, bytes: bytes, path: path, width: width, height: height);
    return result.toJson();
  }
}
