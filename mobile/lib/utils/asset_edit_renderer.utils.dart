import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:openapi/api.dart' show MirrorAxis, MosaicParameters, MosaicStroke, MosaicStrokeMode;

Future<ui.Image> decodeEditableImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

enum RenderFormat { jpeg, png }

typedef RenderedImage = ({Uint8List bytes, int width, int height});

Future<RenderedImage> renderAssetEdits(
  Uint8List bytes,
  List<AssetEdit> edits, {
  RenderFormat format = RenderFormat.jpeg,
  int jpegQuality = 92,
  CensorEffectBuilder? censorEffects,
}) async {
  final original = await decodeEditableImage(bytes);
  return renderEditedImage(
    original,
    edits,
    format: format,
    jpegQuality: jpegQuality,
    censorEffects: censorEffects,
    disposeSource: true,
  );
}

/// Renders [edits] over an already decoded [source] on the GPU. [source] is disposed (as early as possible) only when
/// [disposeSource] is true.
Future<RenderedImage> renderEditedImage(
  ui.Image source,
  List<AssetEdit> edits, {
  RenderFormat format = RenderFormat.jpeg,
  int jpegQuality = 92,
  CensorEffectBuilder? censorEffects,
  bool disposeSource = false,
}) async {
  final mosaic = edits.whereType<MosaicEdit>().firstOrNull;
  final ui.Image? mosaicked;
  try {
    mosaicked = mosaic == null ? null : await _applyMosaic(source, mosaic.parameters, censorEffects);
  } catch (_) {
    if (disposeSource) {
      source.dispose();
    }
    rethrow;
  }
  if (disposeSource && mosaicked != null) {
    source.dispose();
  }

  final ui.Image transformed;
  try {
    transformed = await _applyTransform(mosaicked ?? source, edits);
  } finally {
    mosaicked?.dispose();
    if (disposeSource && mosaicked == null) {
      source.dispose();
    }
  }

  try {
    return await encodeRenderedImage(transformed, format: format, jpegQuality: jpegQuality);
  } finally {
    transformed.dispose();
  }
}

Future<RenderedImage> encodeRenderedImage(
  ui.Image image, {
  RenderFormat format = RenderFormat.jpeg,
  int jpegQuality = 92,
}) async {
  final width = image.width;
  final height = image.height;
  if (format == RenderFormat.png) {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) {
      throw StateError('Unable to encode the rendered image');
    }
    return (bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes), width: width, height: height);
  }

  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) {
    throw StateError('Unable to read the rendered image');
  }
  final pixels = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final jpeg = await Isolate.run(
    () => img.encodeJpg(
      img.Image.fromBytes(width: width, height: height, bytes: pixels.buffer, numChannels: 4),
      quality: jpegQuality,
    ),
  );
  return (bytes: jpeg, width: width, height: height);
}

/// Width and height of an encoded image read from its header, without decoding the pixels.
Future<({int width, int height})> readEncodedImageSize(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
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

/// Renders [edits] on the CPU, for images whose sides exceed the GPU texture limit. Crop, rotation and mirroring are
/// exact at full resolution; mosaic effects and stroke masks are computed at [maskMaxDimension] and scaled up.
Future<RenderedImage> renderLargeAssetEdits(
  Uint8List bytes,
  List<AssetEdit> edits, {
  RenderFormat format = RenderFormat.jpeg,
  int jpegQuality = 92,
  CensorEffectBuilder? censorEffects,
  int maskMaxDimension = 4096,
}) async {
  final mosaic = edits.whereType<MosaicEdit>().firstOrNull;
  final masks = mosaic == null ? null : await _lowResMosaic(bytes, mosaic.parameters, censorEffects, maskMaxDimension);

  final crop = edits.whereType<CropEdit>().firstOrNull?.parameters;
  final mirrors = edits.whereType<MirrorEdit>().map((edit) => edit.parameters.axis).toSet();
  final job = (
    bytes: bytes,
    masks: masks,
    crop: crop == null ? null : (crop.x, crop.y, crop.width, crop.height),
    flipHorizontal: mirrors.contains(MirrorAxis.horizontal),
    flipVertical: mirrors.contains(MirrorAxis.vertical),
    angle: edits.whereType<RotateEdit>().fold(0, (sum, edit) => sum + edit.parameters.angle) % 360,
    png: format == RenderFormat.png,
    jpegQuality: jpegQuality,
  );
  return _runLargeRender(job);
}

typedef _LargeRenderJob = ({
  Uint8List bytes,
  _MosaicMasks? masks,
  (int, int, int, int)? crop,
  bool flipHorizontal,
  bool flipVertical,
  int angle,
  bool png,
  int jpegQuality,
});

// Separate function so the isolate closure captures only the job.
Future<RenderedImage> _runLargeRender(_LargeRenderJob job) => Isolate.run(() => _renderLarge(job));

RenderedImage _renderLarge(_LargeRenderJob job) {
  var image = _decodeOriented(job.bytes);
  final masks = job.masks;
  if (masks != null) {
    _compositeMasks(image, masks);
  }
  final crop = job.crop;
  if (crop != null) {
    image = img.copyCrop(image, x: crop.$1, y: crop.$2, width: crop.$3, height: crop.$4);
  }
  if (job.flipHorizontal && job.flipVertical) {
    image = img.flipHorizontalVertical(image);
  } else if (job.flipHorizontal) {
    image = img.flipHorizontal(image);
  } else if (job.flipVertical) {
    image = img.flipVertical(image);
  }
  if (job.angle != 0) {
    image = img.copyRotate(image, angle: job.angle);
  }
  final encoded = job.png ? img.encodePng(image, level: 4) : img.encodeJpg(image, quality: job.jpegQuality);
  return (bytes: encoded, width: image.width, height: image.height);
}

/// Decodes [bytes] on the CPU into a 4-channel image with EXIF orientation applied (matches Flutter's decoder).
img.Image decodeOrientedImage(Uint8List bytes) => _decodeOriented(bytes);

img.Image _decodeOriented(Uint8List bytes) {
  var image = img.decodeImage(bytes);
  if (image == null) {
    throw StateError('Unable to decode the image');
  }
  final ifd = image.exif.imageIfd;
  if (ifd.hasOrientation && ifd.orientation != 1) {
    image = img.bakeOrientation(image);
  }
  if (image.numChannels != 4 || image.format != img.Format.uint8) {
    image = image.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
  }
  return image;
}

/// Low-resolution mosaic data for [renderLargeAssetEdits]: a label map (0 = untouched, n = effect n - 1) and one RGBA
/// effect image per censor group, all [width] x [height].
typedef _MosaicMasks = ({int width, int height, Uint8List labels, List<Uint8List> effects});

Future<_MosaicMasks?> _lowResMosaic(
  Uint8List bytes,
  MosaicParameters parameters,
  CensorEffectBuilder? censorEffects,
  int maxDimension,
) async {
  final groups = <_CensorGroup>[
    for (final group in {
      for (final stroke in parameters.strokes)
        if (stroke.mode == MosaicStrokeMode.paint) _censorGroup(stroke, parameters.blockSize),
    })
      group,
  ];
  if (groups.isEmpty || censorEffects == null) {
    return null;
  }

  final small = await _runDecodeSmall(bytes, maxDimension);
  final source = await _imageFromRgba(small.small, small.sw, small.sh);
  final effects = <Uint8List>[];
  final labels = <_CensorGroup, int>{};
  try {
    for (final group in groups.take(254)) {
      final options = Map<String, Object?>.from(jsonDecode(group.$3) as Map);
      final effect = await censorEffects(group.$1, options, source, group.$2, small.width, small.height);
      if (effect == null) {
        continue;
      }
      try {
        final scaled = effect.width == small.sw && effect.height == small.sh
            ? effect
            : await _drawToImage(small.sw, small.sh, (canvas) {
                canvas.drawImageRect(
                  effect,
                  Rect.fromLTWH(0, 0, effect.width.toDouble(), effect.height.toDouble()),
                  Rect.fromLTWH(0, 0, small.sw.toDouble(), small.sh.toDouble()),
                  Paint(),
                );
              });
        final data = await scaled.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (!identical(scaled, effect)) {
          scaled.dispose();
        }
        if (data != null) {
          labels[group] = effects.length + 1;
          effects.add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        }
      } finally {
        effect.dispose();
      }
    }
  } finally {
    source.dispose();
  }
  if (effects.isEmpty) {
    return null;
  }

  final scale = small.sw / small.width;
  final mask = await _drawToImage(small.sw, small.sh, (canvas) {
    canvas.scale(scale, scale);
    for (final stroke in parameters.strokes) {
      final label = stroke.mode == MosaicStrokeMode.paint ? labels[_censorGroup(stroke, parameters.blockSize)] : null;
      _drawLabelStroke(canvas, stroke, label);
    }
  });
  try {
    final data = await mask.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      return null;
    }
    final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final labelMap = Uint8List(small.sw * small.sh);
    for (var index = 0; index < labelMap.length; index++) {
      labelMap[index] = rgba[index * 4 + 3] == 0 ? 0 : rgba[index * 4];
    }
    return (width: small.sw, height: small.sh, labels: labelMap, effects: effects);
  } finally {
    mask.dispose();
  }
}

typedef _SmallImage = ({int width, int height, Uint8List small, int sw, int sh});

// Separate function so the isolate closure captures only its arguments.
Future<_SmallImage> _runDecodeSmall(Uint8List bytes, int maxDimension) =>
    Isolate.run(() => _decodeSmall(bytes, maxDimension));

_SmallImage _decodeSmall(Uint8List bytes, int maxDimension) {
  final image = _decodeOriented(bytes);
  final scale = min(1.0, maxDimension / max(image.width, image.height));
  final resized = scale >= 1
      ? image
      : img.copyResize(
          image,
          width: max(1, (image.width * scale).round()),
          height: max(1, (image.height * scale).round()),
          interpolation: img.Interpolation.average,
        );
  return (
    width: image.width,
    height: image.height,
    small: resized.toUint8List(),
    sw: resized.width,
    sh: resized.height,
  );
}

void _drawLabelStroke(Canvas canvas, MosaicStroke stroke, int? label) {
  final paint = Paint()
    ..isAntiAlias = false
    ..color = label == null ? const Color(0x00000000) : Color.fromARGB(255, label, 0, 0)
    ..blendMode = label == null ? BlendMode.clear : BlendMode.src
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = stroke.brushSize;
  final points = stroke.points.map((point) => Offset(point.x, point.y)).toList();
  if (points.isEmpty) {
    return;
  }
  if (points.length == 1) {
    canvas.drawCircle(points.first, stroke.brushSize / 2, paint..style = PaintingStyle.fill);
    return;
  }
  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (final point in points.skip(1)) {
    path.lineTo(point.dx, point.dy);
  }
  canvas.drawPath(path, paint..style = PaintingStyle.stroke);
}

void _compositeMasks(img.Image image, _MosaicMasks masks) {
  final pixels = image.toUint8List();
  final width = image.width;
  final height = image.height;
  final columns = Int32List(width);
  for (var x = 0; x < width; x++) {
    columns[x] = min(masks.width - 1, x * masks.width ~/ width);
  }
  for (var y = 0; y < height; y++) {
    final row = min(masks.height - 1, y * masks.height ~/ height) * masks.width;
    for (var x = 0; x < width; x++) {
      final cell = row + columns[x];
      final label = masks.labels[cell];
      if (label == 0 || label > masks.effects.length) {
        continue;
      }
      final effect = masks.effects[label - 1];
      final from = cell * 4;
      final to = (y * width + x) * 4;
      pixels[to] = effect[from];
      pixels[to + 1] = effect[from + 1];
      pixels[to + 2] = effect[from + 2];
    }
  }
}

Future<ui.Image> _imageFromRgba(Uint8List rgba, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(buffer, width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

Future<ui.Image> _applyTransform(ui.Image source, List<AssetEdit> edits) async {
  final crop = edits.whereType<CropEdit>().firstOrNull?.parameters;
  final cropRect = crop == null
      ? Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble())
      : Rect.fromLTWH(crop.x.toDouble(), crop.y.toDouble(), crop.width.toDouble(), crop.height.toDouble());

  final mirrors = edits.whereType<MirrorEdit>().map((edit) => edit.parameters.axis).toSet();
  final flipHorizontal = mirrors.contains(MirrorAxis.horizontal);
  final flipVertical = mirrors.contains(MirrorAxis.vertical);
  final angle = edits.whereType<RotateEdit>().fold(0, (sum, edit) => sum + edit.parameters.angle) % 360;
  final quarterTurned = angle % 180 != 0;

  final width = (quarterTurned ? cropRect.height : cropRect.width).round();
  final height = (quarterTurned ? cropRect.width : cropRect.height).round();

  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..translate(width / 2, height / 2)
    ..rotate(angle * pi / 180)
    ..scale(flipHorizontal ? -1 : 1, flipVertical ? -1 : 1)
    ..drawImageRect(
      source,
      cropRect,
      Rect.fromCenter(center: Offset.zero, width: cropRect.width, height: cropRect.height),
      Paint()..filterQuality = FilterQuality.high,
    );

  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

typedef CensorEffectBuilder =
    Future<ui.Image?> Function(
      String? style,
      Map<String, Object?> options,
      ui.Image source,
      int size,
      int width,
      int height,
    );

typedef _CensorGroup = (String?, int, String);

int mosaicStrokeBlockSize(MosaicStroke stroke, int defaultBlockSize) =>
    stroke.blockSize.isPresent ? stroke.blockSize.value ?? defaultBlockSize : defaultBlockSize;

String? mosaicStrokeStyle(MosaicStroke stroke) => stroke.style.isPresent ? stroke.style.value : null;

Map<String, Object?> mosaicStrokeStyleOptions(MosaicStroke stroke) =>
    stroke.styleOptions.isPresent ? Map<String, Object?>.from(stroke.styleOptions.value ?? const {}) : const {};

_CensorGroup _censorGroup(MosaicStroke stroke, int defaultBlockSize) => (
  mosaicStrokeStyle(stroke),
  mosaicStrokeBlockSize(stroke, defaultBlockSize),
  jsonEncode(mosaicStrokeStyleOptions(stroke)),
);

Future<ui.Image> downsampleImage(ui.Image source, int cell, {required int width, required int height}) {
  final columns = max(1, (width / cell).ceil());
  final rows = max(1, (height / cell).ceil());
  return _drawToImage(columns, rows, (canvas) {
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, columns.toDouble(), rows.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
  });
}

Future<ui.Image> _applyMosaic(ui.Image source, MosaicParameters parameters, CensorEffectBuilder? censorEffects) async {
  final width = source.width;
  final height = source.height;
  final groups = <_CensorGroup>{
    for (final stroke in parameters.strokes)
      if (stroke.mode == MosaicStrokeMode.paint) _censorGroup(stroke, parameters.blockSize),
  };

  final effects = <_CensorGroup, ui.Image>{};
  try {
    for (final group in groups) {
      final options = Map<String, Object?>.from(jsonDecode(group.$3) as Map);
      final effect = await censorEffects?.call(group.$1, options, source, group.$2, width, height);
      if (effect != null) {
        effects[group] = effect;
      }
    }

    return await _drawToImage(width, height, (canvas) {
      final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      canvas.drawImage(source, Offset.zero, Paint());
      for (final MapEntry(key: group, value: effect) in effects.entries) {
        canvas.saveLayer(bounds, Paint());
        for (final stroke in parameters.strokes) {
          final visible = stroke.mode == MosaicStrokeMode.paint && _censorGroup(stroke, parameters.blockSize) == group;
          _drawMaskStroke(canvas, stroke, visible: visible);
        }
        canvas.drawImageRect(
          effect,
          Rect.fromLTWH(0, 0, effect.width.toDouble(), effect.height.toDouble()),
          bounds,
          Paint()..blendMode = BlendMode.srcIn,
        );
        canvas.restore();
      }
    });
  } finally {
    for (final effect in effects.values) {
      effect.dispose();
    }
  }
}

void _drawMaskStroke(Canvas canvas, MosaicStroke stroke, {required bool visible}) {
  final brushSize = stroke.brushSize;
  final paint = Paint()
    ..color = const Color(0xFFFFFFFF)
    ..blendMode = visible ? BlendMode.srcOver : BlendMode.clear
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = brushSize;

  final points = stroke.points.map((point) => Offset(point.x, point.y)).toList();
  if (points.isEmpty) {
    return;
  }

  if (points.length == 1) {
    canvas.drawCircle(points.first, brushSize / 2, paint..style = PaintingStyle.fill);
    return;
  }

  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (final point in points.skip(1)) {
    path.lineTo(point.dx, point.dy);
  }
  canvas.drawPath(path, paint..style = PaintingStyle.stroke);
}

Future<ui.Image> _drawToImage(int width, int height, void Function(Canvas canvas) draw) async {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}
