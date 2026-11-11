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

Future<Uint8List> renderAssetEdits(Uint8List bytes, List<AssetEdit> edits, {int jpegQuality = 92}) async {
  final original = await decodeEditableImage(bytes);
  final mosaic = edits.whereType<MosaicEdit>().firstOrNull;
  final source = mosaic == null ? original : await _applyMosaic(original, mosaic.parameters);
  if (!identical(source, original)) {
    original.dispose();
  }

  final transformed = await _applyTransform(source, edits);
  source.dispose();

  try {
    final data = await transformed.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('Unable to read the rendered image');
    }

    final width = transformed.width;
    final height = transformed.height;
    final pixels = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    return await Isolate.run(
      () => img.encodeJpg(
        img.Image.fromBytes(width: width, height: height, bytes: pixels.buffer, numChannels: 4),
        quality: jpegQuality,
      ),
    );
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

Future<ui.Image> _applyMosaic(ui.Image source, MosaicParameters parameters) async {
  final width = source.width;
  final height = source.height;
  final blockSize = parameters.blockSize;
  final blocksWide = max(1, (width / blockSize).ceil());
  final blocksHigh = max(1, (height / blockSize).ceil());

  final blocks = await _drawToImage(blocksWide, blocksHigh, (canvas) {
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Rect.fromLTWH(0, 0, blocksWide.toDouble(), blocksHigh.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
  });

  try {
    return await _drawToImage(width, height, (canvas) {
      final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      canvas.drawImage(source, Offset.zero, Paint());
      canvas.saveLayer(bounds, Paint());
      for (final stroke in parameters.strokes) {
        _drawMaskStroke(canvas, stroke);
      }
      canvas.drawImageRect(
        blocks,
        Rect.fromLTWH(0, 0, blocksWide.toDouble(), blocksHigh.toDouble()),
        Rect.fromLTWH(0, 0, (blocksWide * blockSize).toDouble(), (blocksHigh * blockSize).toDouble()),
        Paint()
          ..filterQuality = FilterQuality.none
          ..blendMode = BlendMode.srcIn,
      );
      canvas.restore();
    });
  } finally {
    blocks.dispose();
  }
}

void _drawMaskStroke(Canvas canvas, MosaicStroke stroke) {
  final brushSize = stroke.brushSize;
  final paint = Paint()
    ..color = const Color(0xFFFFFFFF)
    ..blendMode = stroke.mode == MosaicStrokeMode.erase ? BlendMode.clear : BlendMode.srcOver
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
