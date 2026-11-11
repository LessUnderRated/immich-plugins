import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/utils/asset_edit_renderer.utils.dart';
import 'package:openapi/api.dart';

const _red = (255, 0, 0);
const _blue = (0, 0, 255);

Uint8List _halves() {
  final image = img.Image(width: 80, height: 40);
  for (final pixel in image) {
    final isLeft = pixel.x < 40;
    pixel
      ..r = isLeft ? 255 : 0
      ..g = 0
      ..b = isLeft ? 0 : 255;
  }
  return img.encodePng(image);
}

(int, int, int) _colorAt(img.Image image, int x, int y) {
  final pixel = image.getPixel(x, y);
  return (pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt());
}

void _expectColor(img.Image image, int x, int y, (int, int, int) expected) {
  final (r, g, b) = _colorAt(image, x, y);
  expect(
    (r - expected.$1).abs() < 40 && (g - expected.$2).abs() < 40 && (b - expected.$3).abs() < 40,
    isTrue,
    reason: 'pixel ($x, $y) was ($r, $g, $b), expected $expected',
  );
}

Future<img.Image> _render(List<AssetEdit> edits, {CensorEffectBuilder? censorEffects}) async {
  final output = (await renderAssetEdits(_halves(), edits, censorEffects: censorEffects)).bytes;
  return img.decodeJpg(output)!;
}

Future<ui.Image> _solid(int width, int height, ui.Color color) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..color = color);
  return recorder.endRecording().toImage(width, height);
}

MosaicEdit _dot({String? style, Map<String, Object>? options}) => MosaicEdit(
  MosaicParameters(
    blockSize: 8,
    strokes: [
      MosaicStroke(
        mode: MosaicStrokeMode.paint,
        brushSize: 20,
        blockSize: const Optional.present(12),
        style: style == null ? const Optional.absent() : Optional.present(style),
        styleOptions: Optional.present(options ?? const {}),
        points: [MosaicPoint(x: 10, y: 20)],
      ),
    ],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps the image when there are no transform edits', () async {
    final image = await _render(const []);
    expect((image.width, image.height), (80, 40));
    _expectColor(image, 10, 20, _red);
    _expectColor(image, 70, 20, _blue);
  });

  test('crops in original pixels', () async {
    final image = await _render([CropEdit(CropParameters(x: 0, y: 0, width: 30, height: 20))]);
    expect((image.width, image.height), (30, 20));
    _expectColor(image, 15, 10, _red);
  });

  test('rotates clockwise', () async {
    final image = await _render([RotateEdit(RotateParameters(angle: 90))]);
    expect((image.width, image.height), (40, 80));
    _expectColor(image, 20, 10, _red);
    _expectColor(image, 20, 70, _blue);
  });

  test('mirrors horizontally', () async {
    final image = await _render([MirrorEdit(MirrorParameters(axis: MirrorAxis.horizontal))]);
    _expectColor(image, 10, 20, _blue);
    _expectColor(image, 70, 20, _red);
  });

  test('mirrors before rotating', () async {
    final image = await _render([
      MirrorEdit(MirrorParameters(axis: MirrorAxis.horizontal)),
      RotateEdit(RotateParameters(angle: 90)),
    ]);
    expect((image.width, image.height), (40, 80));
    _expectColor(image, 20, 10, _blue);
    _expectColor(image, 20, 70, _red);
  });

  test('draws the plugin effect only under the brush', () async {
    final image = await _render(
      [_dot()],
      censorEffects: (style, options, source, size, width, height) =>
          _solid(source.width, source.height, const ui.Color(0xFF00FF00)),
    );
    final (r, g, b) = _colorAt(image, 10, 20);
    expect(g > 200 && r < 60 && b < 60, isTrue, reason: 'expected the plugin colour, got ($r, $g, $b)');
    _expectColor(image, 70, 20, _blue);
  });

  test('leaves the image unchanged without a censor style plugin', () async {
    final image = await _render([_dot()]);
    _expectColor(image, 10, 20, _red);
  });

  test('passes the stroke style, settings and size to the plugin', () async {
    final calls = <(String?, Map<String, Object?>, int)>[];
    await _render(
      [
        _dot(style: 'censor#hexagon', options: {'borders': false}),
      ],
      censorEffects: (style, options, source, size, width, height) async {
        calls.add((style, options, size));
        return null;
      },
    );
    expect(calls, hasLength(1));
    expect(calls.single.$1, 'censor#hexagon');
    expect(calls.single.$2, {'borders': false});
    expect(calls.single.$3, 12);
  });
}
