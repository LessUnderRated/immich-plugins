import 'dart:math';
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:openapi/api.dart' show MosaicParameters, MosaicPoint, MosaicStroke, MosaicStrokeMode;

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

class MosaicStrokeDraft {
  final List<Offset> points;
  final double brushSize;
  final bool erase;

  const MosaicStrokeDraft({required this.points, required this.brushSize, required this.erase});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MosaicStrokeDraft &&
          other.brushSize == brushSize &&
          other.erase == erase &&
          const ListEquality<Offset>().equals(other.points, points);

  @override
  int get hashCode => Object.hash(brushSize, erase, const ListEquality<Offset>().hash(points));
}

int mosaicBlockPixels(double blockSize, int width, int height) {
  return (blockSize * min(width, height)).round().clamp(2, 1024);
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
  return (
    blockSize: (parameters.blockSize / shortestSide).clamp(minMosaicBlockSize, maxMosaicBlockSize),
    strokes: parameters.strokes
        .map(
          (stroke) => MosaicStrokeDraft(
            points: List.unmodifiable(stroke.points.map((point) => Offset(point.x / width, point.y / height))),
            brushSize: stroke.brushSize / shortestSide,
            erase: stroke.mode == MosaicStrokeMode.erase,
          ),
        )
        .toList(),
  );
}
