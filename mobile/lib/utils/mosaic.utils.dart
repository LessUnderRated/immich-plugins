import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:openapi/api.dart' show MosaicParameters, MosaicPoint, MosaicStroke, MosaicStrokeMode, Optional;

enum EditorMode { transform, mosaic }

enum MosaicTool { brush, eraser }

const double defaultMosaicBrushSize = 0.08;
const double minMosaicBrushSize = 0.01;
const double maxMosaicBrushSize = 0.3;

const double defaultMosaicBlockSize = 0.03;
const double minMosaicBlockSize = 0.005;
const double maxMosaicBlockSize = 0.1;

const int maxMosaicStrokes = 1000;
const int maxMosaicStrokePoints = 10000;
const double minMosaicPointDistance = 0.002;

const mosaicBrushStep = 0.01;
const mosaicBlockStep = 0.005;

class MosaicStrokeDraft {
  final List<Offset> points;
  final double brushSize;
  final double blockSize;
  final bool erase;
  final String? style;
  final Map<String, Object?> styleOptions;

  const MosaicStrokeDraft({
    required this.points,
    required this.brushSize,
    required this.erase,
    this.blockSize = defaultMosaicBlockSize,
    this.style,
    this.styleOptions = const {},
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MosaicStrokeDraft &&
          other.brushSize == brushSize &&
          other.blockSize == blockSize &&
          other.erase == erase &&
          other.style == style &&
          const DeepCollectionEquality().equals(other.styleOptions, styleOptions) &&
          const ListEquality<Offset>().equals(other.points, points);

  @override
  int get hashCode => Object.hash(
    brushSize,
    blockSize,
    erase,
    style,
    const DeepCollectionEquality().hash(styleOptions),
    const ListEquality<Offset>().hash(points),
  );
}

int mosaicBlockPixels(double blockSize, int width, int height) {
  return (blockSize * min(width, height)).round().clamp(2, 1024);
}

int mosaicBrushPixels(double brushSize, int width, int height) {
  return max(1, (brushSize * min(width, height)).round());
}

MosaicParameters? mosaicToParameters(List<MosaicStrokeDraft> strokes, double blockSize, int width, int height) {
  if (!strokes.any((stroke) => !stroke.erase) || width <= 0 || height <= 0) {
    return null;
  }

  final shortestSide = min(width, height);
  return MosaicParameters(
    blockSize: mosaicBlockPixels(blockSize, width, height),
    strokes: strokes
        .take(maxMosaicStrokes)
        .map(
          (stroke) => MosaicStroke(
            mode: stroke.erase ? MosaicStrokeMode.erase : MosaicStrokeMode.paint,
            brushSize: max(stroke.brushSize * shortestSide, 1),
            blockSize: Optional.present(mosaicBlockPixels(stroke.blockSize, width, height)),
            style: stroke.style == null ? const Optional.absent() : Optional.present(stroke.style),
            styleOptions: Optional.present({
              for (final MapEntry(:key, :value) in stroke.styleOptions.entries) key: ?value,
            }),
            points: stroke.points
                .take(maxMosaicStrokePoints)
                .map((point) => MosaicPoint(x: point.dx * width, y: point.dy * height))
                .toList(),
          ),
        )
        .toList(),
  );
}

({List<MosaicStrokeDraft> strokes, double blockSize}) mosaicFromParameters(
  MosaicParameters parameters,
  int width,
  int height,
) {
  final shortestSide = min(width, height);
  double toFraction(int pixels) => pixels / shortestSide;

  return (
    blockSize: toFraction(parameters.blockSize),
    strokes: parameters.strokes
        .map(
          (stroke) => MosaicStrokeDraft(
            points: List.unmodifiable(stroke.points.map((point) => Offset(point.x / width, point.y / height))),
            brushSize: stroke.brushSize / shortestSide,
            blockSize: toFraction(
              stroke.blockSize.isPresent ? stroke.blockSize.value ?? parameters.blockSize : parameters.blockSize,
            ),
            erase: stroke.mode == MosaicStrokeMode.erase,
            style: stroke.style.isPresent ? stroke.style.value : null,
            styleOptions: stroke.styleOptions.isPresent
                ? Map<String, Object?>.from(stroke.styleOptions.value ?? const {})
                : const {},
          ),
        )
        .toList(),
  );
}

String mosaicEffectKey(MosaicStrokeDraft stroke, int width, int height) =>
    '${stroke.style}|${mosaicBlockPixels(stroke.blockSize, width, height)}|${jsonEncode(stroke.styleOptions)}';
