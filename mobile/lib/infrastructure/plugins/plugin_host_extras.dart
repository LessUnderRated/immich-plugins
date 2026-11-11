import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class PluginHostExtras {
  final Future<Directory> Function() _pluginsRoot;

  const PluginHostExtras(this._pluginsRoot);

  Future<Directory> _dataDir(String plugin) async {
    final directory = Directory(p.join((await _pluginsRoot()).path, 'data', plugin));
    await directory.create(recursive: true);
    return directory;
  }

  Future<String> _resolve(String plugin, String path) async =>
      p.isAbsolute(path) ? path : p.join((await _dataDir(plugin)).path, path);

  Future<Map<String, dynamic>> readFile(String plugin, String path) async {
    final file = File(await _resolve(plugin, path));
    final bytes = await file.readAsBytes();
    return {'path': file.path, 'size': bytes.length, 'base64': base64Encode(bytes)};
  }

  Future<Map<String, dynamic>> writeFile(String plugin, String path, Map<String, dynamic> options) async {
    final file = File(await _resolve(plugin, path));
    await file.parent.create(recursive: true);
    final base64 = options['base64'];
    final text = options['text'];
    final append = options['append'] == true;
    final mode = append ? FileMode.append : FileMode.write;
    if (base64 is String) {
      await file.writeAsBytes(base64Decode(base64), mode: mode, flush: true);
    } else {
      await file.writeAsString(text is String ? text : '', mode: mode, flush: true);
    }
    return {'path': file.path, 'size': await file.length()};
  }

  Future<List<Map<String, dynamic>>> listFiles(String plugin, String path) async {
    final directory = Directory(await _resolve(plugin, path.isEmpty ? '.' : path));
    if (!directory.existsSync()) {
      return const [];
    }
    return [
      for (final entity in directory.listSync())
        {
          'path': entity.path,
          'name': p.basename(entity.path),
          'isDirectory': entity is Directory,
          'size': entity is File ? entity.lengthSync() : 0,
        },
    ];
  }

  Future<void> deleteFile(String plugin, String path) async {
    final resolved = await _resolve(plugin, path);
    final type = FileSystemEntity.typeSync(resolved);
    if (type == FileSystemEntityType.directory) {
      await Directory(resolved).delete(recursive: true);
    } else if (type != FileSystemEntityType.notFound) {
      await File(resolved).delete();
    }
  }

  Future<File> _storageFile(String plugin) async => File(p.join((await _dataDir(plugin)).path, 'storage.json'));

  Future<Map<String, dynamic>> _readStorage(String plugin) async {
    final file = await _storageFile(plugin);
    if (!file.existsSync()) {
      return {};
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<Object?> getStorage(String plugin, String key) async {
    final storage = await _readStorage(plugin);
    return key.isEmpty ? storage : storage[key];
  }

  Future<void> setStorage(String plugin, String key, Object? value) async {
    final storage = await _readStorage(plugin);
    value == null ? storage.remove(key) : storage[key] = value;
    final file = await _storageFile(plugin);
    await file.writeAsString(jsonEncode(storage), flush: true);
  }

  static Future<Map<String, dynamic>> encodePixels(Uint8List bytes, {int? maxSize}) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    var image = frame.image;
    try {
      final longest = image.width > image.height ? image.width : image.height;
      if (maxSize != null && maxSize > 0 && longest > maxSize) {
        final scale = maxSize / longest;
        final width = (image.width * scale).round().clamp(1, maxSize);
        final height = (image.height * scale).round().clamp(1, maxSize);
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawImageRect(
          image,
          ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
        final picture = recorder.endRecording();
        final scaled = await picture.toImage(width, height);
        picture.dispose();
        image.dispose();
        image = scaled;
      }

      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        throw StateError('Unable to read pixels');
      }
      return {
        'width': image.width,
        'height': image.height,
        'rgba': base64Encode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)),
      };
    } finally {
      image.dispose();
    }
  }

  static Future<Uint8List> decodePixels(Map<String, dynamic> image, {required bool png}) async {
    final encoded = image['encoded'];
    if (encoded is String) {
      return base64Decode(encoded);
    }

    final width = image['width'];
    final height = image['height'];
    final rgba = image['rgba'];
    if (width is! int || height is! int || rgba is! String) {
      throw ArgumentError('writeImage needs width, height and rgba, or encoded');
    }
    final pixels = base64Decode(rgba);
    if (pixels.length != width * height * 4) {
      throw ArgumentError('rgba must contain width * height * 4 bytes');
    }
    return Isolate.run(() {
      final decoded = img.Image.fromBytes(width: width, height: height, bytes: pixels.buffer, numChannels: 4);
      return png ? img.encodePng(decoded) : img.encodeJpg(decoded, quality: 92);
    });
  }
}
