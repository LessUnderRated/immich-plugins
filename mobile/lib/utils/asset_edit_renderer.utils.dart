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
  final mosaic = edits.whereType<MosaicEdit>().firstOrNull;
  final source = mosaic == null ? original : await _applyMosaic(original, mosaic.parameters, censorEffects);
  if (!identical(source, original)) {
    original.dispose();
  }

  final transformed = await _applyTransform(source, edits);
  source.dispose();

  try {
    final width = transformed.width;
    final height = transformed.height;
    if (format == RenderFormat.png) {
      final png = await transformed.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) {
        throw StateError('Unable to encode the rendered image');
      }
      return (bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes), width: width, height: height);
    }

    final data = await transformed.toByteData(format: ui.ImageByteFormat.rawRgba);
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
  } finally {
    transformed.dispose();
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
