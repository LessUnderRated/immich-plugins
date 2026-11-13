import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_tool_protocol.dart';
import 'package:immich_mobile/utils/asset_edit_renderer.utils.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _png = 'image/png';
const _jpeg = 'image/jpeg';
const _webp = 'image/webp';

/// Mime type of an encoded image from its first bytes, or null when it is not PNG, JPEG or WebP.
String? sniffImageMime(Uint8List head) {
  if (head.length >= 8 && head[0] == 0x89 && head[1] == 0x50 && head[2] == 0x4E && head[3] == 0x47) {
    return _png;
  }
  if (head.length >= 3 && head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF) {
    return _jpeg;
  }
  if (head.length >= 12 &&
      String.fromCharCodes(head.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(head.sublist(8, 12)) == 'WEBP') {
    return _webp;
  }
  return null;
}

String _extension(String mime) => switch (mime) {
  _png => '.png',
  _webp => '.webp',
  _ => '.jpg',
};

/// The image the editor works on: an encoded file plus its size (as displayed, EXIF orientation applied).
class EditorWorkingImage {
  final File file;
  final int width;
  final int height;
  final String mime;

  /// 0 for the asset itself, then +1 for every tool result.
  final int generation;

  /// True when the file has no EXIF orientation (written by the editor or a tool), so it can be handed to plugins
  /// as it is.
  final bool normalized;

  const EditorWorkingImage({
    required this.file,
    required this.width,
    required this.height,
    required this.mime,
    required this.generation,
    this.normalized = true,
  });

  int get pixels => width * height;

  bool get exceedsGpu => max(width, height) > editorMaxGpuDimension;

  String get extension => _extension(mime);

  RenderFormat get renderFormat => mime == _png ? RenderFormat.png : RenderFormat.jpeg;

  /// Provider for showing the image, decoded at most [maxDimension] on its longest side.
  ImageProvider displayProvider({int maxDimension = editorDisplayMaxDimension}) {
    final provider = FileImage(file);
    final longest = max(width, height);
    if (longest <= maxDimension) {
      return provider;
    }
    final scale = maxDimension / longest;
    return ResizeImage(
      provider,
      width: max(1, (width * scale).round()),
      height: max(1, (height * scale).round()),
      allowUpscaling: false,
    );
  }

  EditorImageRef toRef() =>
      EditorImageRef(path: file.path, width: width, height: height, format: EditorImageFormat.encoded, mime: mime);

  EditorWorkingImage withGeneration(int generation) => EditorWorkingImage(
    file: file,
    width: width,
    height: height,
    mime: mime,
    generation: generation,
    normalized: normalized,
  );

  Map<String, dynamic> toJson() => {
    'path': file.path,
    'width': width,
    'height': height,
    'format': EditorImageFormat.encoded.name,
    'mime': mime,
    'generation': generation,
  };
}

/// Temporary files of one editor session: the working images, tool sources and tool results.
///
/// Lives in `<tmp>/editor/<session>` and is deleted when the editor closes (leftovers of earlier sessions are purged
/// when the next one opens).
class EditorImageWorkspace {
  static const _folder = 'editor';

  final Directory directory;
  int _counter = 0;

  EditorImageWorkspace._(this.directory);

  static Future<Directory> _root() async => Directory(p.join((await getTemporaryDirectory()).path, _folder));

  static Future<EditorImageWorkspace> open(String session) async {
    final directory = Directory(p.join((await _root()).path, session));
    await directory.create(recursive: true);
    return EditorImageWorkspace._(directory);
  }

  /// Deletes the folders of every session except [keep].
  static Future<void> purge({String? keep}) async {
    final root = await _root();
    if (!root.existsSync()) {
      return;
    }
    for (final entry in root.listSync().whereType<Directory>()) {
      if (p.basename(entry.path) != keep) {
        await entry.delete(recursive: true).catchError((_) => entry);
      }
    }
  }

  File newFile(String name, String extension) =>
      File(p.join(directory.path, '${_counter++}-${DateTime.now().microsecondsSinceEpoch}-$name$extension'));

  bool owns(String path) => p.isWithin(directory.path, path);

  Future<void> deletePath(String? path) async {
    if (path == null || !owns(path)) {
      return;
    }
    final file = File(path);
    if (file.existsSync()) {
      await file.delete().catchError((_) => file);
    }
  }

  Future<void> deleteImage(EditorWorkingImage? image) => deletePath(image?.file.path);

  Future<void> dispose() async {
    if (directory.existsSync()) {
      await directory.delete(recursive: true).catchError((_) => directory);
    }
  }

  /// Stores encoded image [bytes]. [width] and [height] are read from the header when not given.
  Future<EditorWorkingImage> writeEncoded(
    Uint8List bytes, {
    required int generation,
    int? width,
    int? height,
    bool normalized = true,
    String name = 'image',
  }) async {
    final mime = sniffImageMime(bytes);
    if (mime == null) {
      throw const EditorToolException('Unsupported image format (use PNG, JPEG or WebP)');
    }
    final size = width != null && height != null ? (width: width, height: height) : await readEncodedImageSize(bytes);
    final file = newFile(name, _extension(mime));
    await file.writeAsBytes(bytes, flush: true);
    return EditorWorkingImage(
      file: file,
      width: size.width,
      height: size.height,
      mime: mime,
      generation: generation,
      normalized: normalized,
    );
  }

  /// Stores a decoded image as PNG.
  Future<EditorWorkingImage> writeImage(ui.Image image, {required int generation, String name = 'image'}) async {
    final rendered = await encodeRenderedImage(image, format: RenderFormat.png);
    return writeEncoded(
      rendered.bytes,
      generation: generation,
      width: rendered.width,
      height: rendered.height,
      name: name,
    );
  }

  /// Takes over a tool result: validates it against [limits], encodes raw RGBA as PNG, moves encoded files into the
  /// workspace and deletes the plugin's file.
  Future<EditorWorkingImage> adopt(
    EditorImageRef result, {
    required int generation,
    EditorToolLimits limits = const EditorToolLimits(),
  }) async {
    final source = File(result.path);
    if (!source.existsSync()) {
      throw EditorToolException('The tool result ${result.path} does not exist');
    }
    try {
      if (result.format == EditorImageFormat.rgba) {
        limits.check(result.width, result.height);
        final length = await source.length();
        if (length != result.width * result.height * 4) {
          throw EditorToolException(
            'The rgba result has $length bytes, expected ${result.width} x ${result.height} x 4',
          );
        }
        final target = newFile('result', '.png');
        final png = max(result.width, result.height) <= editorMaxGpuDimension
            ? await _encodeRgbaOnGpu(await source.readAsBytes(), result.width, result.height)
            : await _runEncodeRgbaFile(result.path, result.width, result.height);
        await target.writeAsBytes(png, flush: true);
        return EditorWorkingImage(
          file: target,
          width: result.width,
          height: result.height,
          mime: _png,
          generation: generation,
        );
      }

      final head = await source.openRead(0, 16).fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
      final mime = sniffImageMime(Uint8List.fromList(head));
      if (mime == null) {
        throw const EditorToolException('Unsupported result format (use PNG, JPEG, WebP or rgba)');
      }
      final size = await _readFileSize(source.path);
      limits.check(size.width, size.height);
      final target = newFile('result', _extension(mime));
      if (owns(source.path)) {
        await source.rename(target.path);
      } else {
        await source.copy(target.path);
      }
      return EditorWorkingImage(
        file: target,
        width: size.width,
        height: size.height,
        mime: mime,
        generation: generation,
      );
    } finally {
      if (!owns(source.path) && source.existsSync()) {
        await source.delete().catchError((_) => source);
      }
    }
  }

  /// Writes [image] in the [format] a tool asked for, downscaled to [maxDimension] when given. Returns the image's own
  /// file when it already matches. Files this returns are deleted by the caller after the tool call (never the
  /// working image itself, see [owns] and [isWorkingFile]).
  Future<EditorImageRef> writeToolSource(
    EditorWorkingImage image,
    EditorSourceFormat format, {
    int? maxDimension,
  }) async {
    final longest = max(image.width, image.height);
    final scale = maxDimension == null || longest <= maxDimension ? 1.0 : maxDimension / longest;
    final width = max(1, (image.width * scale).round());
    final height = max(1, (image.height * scale).round());
    if (scale == 1 && image.normalized && format != EditorSourceFormat.rgba && image.mime == format.mime) {
      return image.toRef();
    }

    final target = newFile('source', switch (format) {
      EditorSourceFormat.rgba => '.rgba',
      EditorSourceFormat.png => '.png',
      EditorSourceFormat.jpeg => '.jpg',
    });

    if (image.exceedsGpu) {
      await _runConvertFile(image.file.path, target.path, format.name, width, height);
    } else {
      final decoded = await decodeEditableImage(await image.file.readAsBytes());
      final ui.Image scaled;
      try {
        scaled = scale == 1 ? decoded : await _scaleOnGpu(decoded, width, height);
      } finally {
        if (scale != 1) {
          decoded.dispose();
        }
      }
      try {
        final Uint8List bytes;
        if (format == EditorSourceFormat.rgba) {
          final data = await scaled.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
          if (data == null) {
            throw StateError('Unable to read the image');
          }
          bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        } else {
          bytes = (await encodeRenderedImage(
            scaled,
            format: format == EditorSourceFormat.png ? RenderFormat.png : RenderFormat.jpeg,
            jpegQuality: 95,
          )).bytes;
        }
        await target.writeAsBytes(bytes, flush: true);
      } finally {
        scaled.dispose();
      }
    }

    return EditorImageRef(
      path: target.path,
      width: width,
      height: height,
      format: format.transport,
      mime: format == EditorSourceFormat.rgba ? null : format.mime,
    );
  }

  static bool isWorkingFile(EditorImageRef ref, EditorWorkingImage image) => ref.path == image.file.path;
}

Future<({int width, int height})> _readFileSize(String path) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      return (width: descriptor.width, height: descriptor.height);
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

Future<ui.Image> _scaleOnGpu(ui.Image source, int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    source,
    ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> _encodeRgbaOnGpu(Uint8List rgba, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(buffer, width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  try {
    final image = (await codec.getNextFrame()).image;
    try {
      return (await encodeRenderedImage(image, format: RenderFormat.png)).bytes;
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

// The isolate entry points below are separate functions so their closures capture only their arguments.

Future<Uint8List> _runEncodeRgbaFile(String path, int width, int height) =>
    Isolate.run(() => _encodeRgbaFile(path, width, height));

Uint8List _encodeRgbaFile(String path, int width, int height) {
  final rgba = File(path).readAsBytesSync();
  return img.encodePng(img.Image.fromBytes(width: width, height: height, bytes: rgba.buffer, numChannels: 4), level: 4);
}

Future<void> _runConvertFile(String from, String to, String format, int width, int height) =>
    Isolate.run(() => _convertFile(from, to, format, width, height));

void _convertFile(String from, String to, String format, int width, int height) {
  var image = decodeOrientedImage(File(from).readAsBytesSync());
  if (image.width != width || image.height != height) {
    image = img.copyResize(image, width: width, height: height, interpolation: img.Interpolation.average);
  }
  final bytes = switch (format) {
    'rgba' => image.toUint8List(),
    'png' => img.encodePng(image, level: 4),
    _ => img.encodeJpg(image, quality: 95),
  };
  File(to).writeAsBytesSync(bytes, flush: true);
}
