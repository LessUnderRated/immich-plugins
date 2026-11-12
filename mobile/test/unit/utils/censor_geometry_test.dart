import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/censor_geometry.dart';

void main() {
  final sampler = GridSampler(
    rgba: Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]),
    width: 2,
    height: 1,
    cell: 50,
  );
  const size = Size(100, 50);

  test('tiles a square lattice and colours each tile from the image', () {
    final tiles = buildCensorTiles(
      {
        'polygons': [
          [0, 0, 50, 0, 50, 50, 0, 50],
        ],
        'a': [50, 0],
        'b': [0, 50],
      },
      size,
      sampler,
    );

    final inside = tiles.where((tile) => tile.points.first.dx >= 0 && tile.points.first.dy >= 0).toList();
    expect(inside.map((tile) => tile.points.first), containsAll([Offset.zero, const Offset(50, 0)]));
    expect(inside.firstWhere((tile) => tile.points.first == Offset.zero).color, const Color(0xFFFF0000));
    expect(inside.firstWhere((tile) => tile.points.first == const Offset(50, 0)).color, const Color(0xFF0000FF));
  });

  test('ignores tiles with a degenerate lattice', () {
    expect(
      buildCensorTiles(
        {
          'polygons': [
            [0, 0, 1, 0, 1, 1],
          ],
          'a': [10, 0],
          'b': [20, 0],
        },
        size,
        sampler,
      ),
      isEmpty,
    );
  });

  test('builds jittered cells that cover the image without overlapping centres', () {
    final cells = buildCensorCells(
      {
        'grid': {'size': 20, 'jitter': 0.7},
      },
      size,
      sampler,
    );
    expect(cells, isNotEmpty);
    for (final cell in cells) {
      expect(cell.points.length, greaterThanOrEqualTo(3));
    }
    final area = cells.fold<double>(0, (sum, cell) {
      var twice = 0.0;
      for (var index = 0; index < cell.points.length; index++) {
        final a = cell.points[index];
        final b = cell.points[(index + 1) % cell.points.length];
        twice += a.dx * b.dy - b.dx * a.dy;
      }
      return sum + twice.abs() / 2;
    });
    expect(area, greaterThan(size.width * size.height));
  });

  test('adds a border polygon under each cell when borders are on', () {
    final plain = buildCensorCells(
      {
        'grid': {'size': 20},
      },
      size,
      sampler,
    );
    final bordered = buildCensorCells(
      {
        'grid': {'size': 20},
        'borders': {
          'width': 2,
          'color': [10, 10, 10],
        },
      },
      size,
      sampler,
    );
    expect(bordered.length, plain.length * 2);
    expect(bordered.first.color, const Color(0xFF0A0A0A));
  });

  test('samples shape colours when the plugin leaves them out', () {
    final shapes = buildCensorShapes([
      {
        'points': [60, 0, 90, 0, 90, 40],
      },
      {
        'points': [0, 0, 10, 0, 10, 10],
        'color': [1, 2, 3],
      },
    ], sampler);
    expect(shapes[0].color, const Color(0xFF0000FF));
    expect(shapes[1].color, const Color(0xFF010203));
  });

  test('matches the server cell hash', () {
    expect(censorCellHash(0, 0, 1), closeTo(0.296658787945, 1e-9));
    expect(censorCellHash(3, 7, 2), closeTo(0.641872804063, 1e-9));
    expect(censorCellHash(-1, 5, 1), closeTo(0.450154620793, 1e-9));
  });
}
