import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

typedef CensorPolygon = ({List<Offset> points, Color color});

const _maxPolygons = 250000;

class GridSampler {
  final Uint8List rgba;
  final int width;
  final int height;
  final int cell;

  const GridSampler({required this.rgba, required this.width, required this.height, required this.cell});

  Color sample(double x, double y) {
    final column = (x / cell).floor().clamp(0, width - 1);
    final row = (y / cell).floor().clamp(0, height - 1);
    final offset = (row * width + column) * 4;
    return Color.fromARGB(255, rgba[offset], rgba[offset + 1], rgba[offset + 2]);
  }
}

List<Offset> _points(Object? value) {
  if (value is! List) {
    return const [];
  }
  return [
    for (var index = 0; index + 1 < value.length; index += 2)
      Offset((value[index] as num).toDouble(), (value[index + 1] as num).toDouble()),
  ];
}

Offset _vector(Object? value, Offset fallback) {
  final points = _points(value);
  return points.isEmpty ? fallback : points.first;
}

Color? parseCensorColor(Object? value) {
  if (value is List && value.length >= 3) {
    final alpha = value.length > 3 ? (value[3] as num).toInt() : 255;
    return Color.fromARGB(alpha, (value[0] as num).toInt(), (value[1] as num).toInt(), (value[2] as num).toInt());
  }
  if (value is String && value.startsWith('#') && value.length == 7) {
    return Color(int.parse('ff${value.substring(1)}', radix: 16));
  }
  return null;
}

Offset _centroid(List<Offset> points) {
  var x = 0.0;
  var y = 0.0;
  for (final point in points) {
    x += point.dx;
    y += point.dy;
  }
  return Offset(x / points.length, y / points.length);
}

bool _outside(List<Offset> points, Size size) {
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  for (final point in points) {
    minX = min(minX, point.dx);
    minY = min(minY, point.dy);
    maxX = max(maxX, point.dx);
    maxY = max(maxY, point.dy);
  }
  return maxX < 0 || maxY < 0 || minX > size.width || minY > size.height;
}

List<CensorPolygon> buildCensorShapes(Object? shapes, GridSampler sampler) {
  if (shapes is! List) {
    return const [];
  }
  final result = <CensorPolygon>[];
  for (final shape in shapes.whereType<Map>()) {
    final points = _points(shape['points']);
    if (points.length < 3) {
      continue;
    }
    final at = _vector(shape['sample'], _centroid(points));
    result.add((points: points, color: parseCensorColor(shape['color']) ?? sampler.sample(at.dx, at.dy)));
  }
  return result;
}

List<CensorPolygon> buildCensorTiles(Object? tiles, Size size, GridSampler sampler) {
  if (tiles is! Map) {
    return const [];
  }
  final polygons = [
    for (final polygon in (tiles['polygons'] as List? ?? const []))
      if (_points(polygon).length >= 3) _points(polygon),
  ];
  final a = _vector(tiles['a'], Offset.zero);
  final b = _vector(tiles['b'], Offset.zero);
  final origin = _vector(tiles['origin'], Offset.zero);
  final determinant = a.dx * b.dy - a.dy * b.dx;
  if (polygons.isEmpty || determinant.abs() < 1e-6) {
    return const [];
  }

  var minI = double.infinity;
  var maxI = double.negativeInfinity;
  var minJ = double.infinity;
  var maxJ = double.negativeInfinity;
  for (final corner in [Offset.zero, Offset(size.width, 0), Offset(0, size.height), Offset(size.width, size.height)]) {
    final point = corner - origin;
    final i = (point.dx * b.dy - point.dy * b.dx) / determinant;
    final j = (a.dx * point.dy - a.dy * point.dx) / determinant;
    minI = min(minI, i);
    maxI = max(maxI, i);
    minJ = min(minJ, j);
    maxJ = max(maxJ, j);
  }

  final result = <CensorPolygon>[];
  for (var j = minJ.floor() - 2; j <= maxJ.ceil() + 2; j++) {
    for (var i = minI.floor() - 2; i <= maxI.ceil() + 2; i++) {
      final offset = origin + a * i.toDouble() + b * j.toDouble();
      for (final polygon in polygons) {
        final points = [for (final point in polygon) point + offset];
        if (_outside(points, size)) {
          continue;
        }
        final center = _centroid(points);
        result.add((points: points, color: sampler.sample(center.dx, center.dy)));
        if (result.length >= _maxPolygons) {
          return result;
        }
      }
    }
  }
  return result;
}

double censorCellHash(int i, int j, int salt) {
  int imul(int a, int b) => (a * b) & 0xFFFFFFFF;
  var hash = (imul(i, 73856093) ^ imul(j, 19349663) ^ salt) & 0xFFFFFFFF;
  hash = imul(hash ^ (hash >>> 13), 1274126177);
  return ((hash ^ (hash >>> 16)) & 0xFFFFFFFF) / 4294967295;
}

List<Offset> _clipHalfPlane(List<Offset> polygon, Offset own, Offset other) {
  final normal = other - own;
  final limit = (other.distanceSquared - own.distanceSquared) / 2;
  bool inside(Offset point) => point.dx * normal.dx + point.dy * normal.dy <= limit;
  final output = <Offset>[];
  for (var index = 0; index < polygon.length; index++) {
    final current = polygon[index];
    final next = polygon[(index + 1) % polygon.length];
    final currentInside = inside(current);
    if (currentInside) {
      output.add(current);
    }
    if (currentInside != inside(next)) {
      final currentValue = current.dx * normal.dx + current.dy * normal.dy - limit;
      final nextValue = next.dx * normal.dx + next.dy * normal.dy - limit;
      output.add(Offset.lerp(current, next, currentValue / (currentValue - nextValue))!);
    }
  }
  return output;
}

List<CensorPolygon> buildCensorCells(Object? cells, Size size, GridSampler sampler) {
  if (cells is! Map) {
    return const [];
  }

  final seeds = <Offset>[];
  var spacing = 0.0;
  final grid = cells['grid'];
  if (grid is Map) {
    spacing = (grid['size'] as num?)?.toDouble() ?? 0;
    if (spacing <= 0) {
      return const [];
    }
    final jitter = ((grid['jitter'] as num?)?.toDouble() ?? 0.7).clamp(0.0, 1.0);
    final salt = (grid['seed'] as num?)?.toInt() ?? 0;
    final columns = (size.width / spacing).ceil();
    final rows = (size.height / spacing).ceil();
    for (var j = -1; j <= rows; j++) {
      for (var i = -1; i <= columns; i++) {
        seeds.add(
          Offset(
            (i + (1 - jitter) / 2 + jitter * censorCellHash(i, j, 1 + salt * 2)) * spacing,
            (j + (1 - jitter) / 2 + jitter * censorCellHash(i, j, 2 + salt * 2)) * spacing,
          ),
        );
      }
    }
  } else {
    seeds.addAll(_points(cells['seeds']));
    if (seeds.isEmpty) {
      return const [];
    }
    spacing = sqrt(size.width * size.height / seeds.length);
  }
  if (seeds.length > _maxPolygons) {
    return const [];
  }

  final buckets = <(int, int), List<Offset>>{};
  (int, int) bucketOf(Offset point) => ((point.dx / spacing).floor(), (point.dy / spacing).floor());
  for (final seed in seeds) {
    buckets.putIfAbsent(bucketOf(seed), () => []).add(seed);
  }

  final borders = cells['borders'];
  final borderWidth = borders is Map ? ((borders['width'] as num?)?.toDouble() ?? 0) : 0.0;
  final borderColor = borders is Map ? parseCensorColor(borders['color']) ?? const Color(0xFF191919) : null;

  final result = <CensorPolygon>[];
  for (final seed in seeds) {
    final (bx, by) = bucketOf(seed);
    var polygon = [
      seed + Offset(-2 * spacing, -2 * spacing),
      seed + Offset(2 * spacing, -2 * spacing),
      seed + Offset(2 * spacing, 2 * spacing),
      seed + Offset(-2 * spacing, 2 * spacing),
    ];
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        for (final other in buckets[(bx + dx, by + dy)] ?? const <Offset>[]) {
          if (other != seed) {
            polygon = _clipHalfPlane(polygon, seed, other);
          }
        }
      }
    }
    if (polygon.length < 3 || _outside(polygon, size)) {
      continue;
    }

    final color = sampler.sample(seed.dx, seed.dy);
    if (borderColor == null || borderWidth <= 0) {
      result.add((points: polygon, color: color));
      continue;
    }

    result.add((points: polygon, color: borderColor));
    result.add((
      points: [
        for (final point in polygon)
          Offset.lerp(point, seed, min(0.9, borderWidth / max(1e-6, (seed - point).distance)))!,
      ],
      color: color,
    ));
  }
  return result;
}
