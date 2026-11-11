import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/mosaic.utils.dart';
import 'package:openapi/api.dart';

void main() {
  const paint = MosaicStrokeDraft(points: [Offset(0.5, 0.25), Offset(0.75, 0.5)], brushSize: 0.1, erase: false);
  const erase = MosaicStrokeDraft(points: [Offset(0.5, 0.25)], brushSize: 0.05, erase: true);

  group('mosaicToParameters', () {
    test('returns null when there are no strokes', () {
      expect(mosaicToParameters(const [], 0.03, 4000, 3000), isNull);
    });

    test('returns null when there are only erase strokes', () {
      expect(mosaicToParameters(const [erase], 0.03, 4000, 3000), isNull);
    });

    test('converts normalized strokes into original image pixels', () {
      final parameters = mosaicToParameters(const [paint, erase], 0.03, 4000, 3000)!;

      expect(parameters.blockSize, 90);
      expect(parameters.strokes, hasLength(2));
      expect(parameters.strokes[0].mode, MosaicStrokeMode.paint);
      expect(parameters.strokes[0].brushSize, closeTo(300, 0.001));
      expect(parameters.strokes[0].points.map((point) => (point.x, point.y)), [(2000.0, 750.0), (3000.0, 1500.0)]);
      expect(parameters.strokes[1].mode, MosaicStrokeMode.erase);
      expect(parameters.strokes[1].brushSize, closeTo(150, 0.001));
    });

    test('keeps the block size of each stroke', () {
      const coarse = MosaicStrokeDraft(points: [Offset(0.1, 0.1)], brushSize: 0.1, blockSize: 0.1, erase: false);
      final parameters = mosaicToParameters(const [paint, coarse], 0.03, 4000, 3000)!;

      expect(parameters.strokes[0].blockSize.value, 90);
      expect(parameters.strokes[1].blockSize.value, 300);
    });

    test('never produces a block smaller than the server minimum', () {
      expect(mosaicToParameters(const [paint], 0.0001, 100, 100)!.blockSize, 2);
    });
  });

  group('mosaicFromParameters', () {
    test('falls back to the edit block size for strokes without one', () {
      final parameters = MosaicParameters.fromJson({
        'blockSize': 60,
        'strokes': [
          {
            'mode': 'paint',
            'brushSize': 100,
            'points': [
              {'x': 10, 'y': 10},
            ],
          },
          {
            'mode': 'paint',
            'brushSize': 100,
            'blockSize': 150,
            'points': [
              {'x': 20, 'y': 20},
            ],
          },
        ],
      })!;

      final result = mosaicFromParameters(parameters, 4000, 3000);
      expect(result.strokes[0].blockSize, closeTo(0.02, 0.0001));
      expect(result.strokes[1].blockSize, closeTo(0.05, 0.0001));
    });

    test('round trips with mosaicToParameters', () {
      final parameters = mosaicToParameters(const [paint, erase], 0.03, 4000, 3000)!;
      final result = mosaicFromParameters(parameters, 4000, 3000);

      expect(result.blockSize, closeTo(0.03, 0.0001));
      expect(result.strokes, const [paint, erase]);
    });

    test('accepts whole numbers stored by the server', () {
      final parameters = MosaicParameters.fromJson({
        'blockSize': 40,
        'strokes': [
          {
            'mode': 'paint',
            'brushSize': 200,
            'points': [
              {'x': 100, 'y': 50},
            ],
          },
        ],
      })!;

      final result = mosaicFromParameters(parameters, 1000, 500);
      expect(result.strokes.single.points.single, const Offset(0.1, 0.1));
      expect(result.strokes.single.brushSize, closeTo(0.4, 0.0001));
    });
  });
}
