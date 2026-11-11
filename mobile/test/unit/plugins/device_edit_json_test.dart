import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/infrastructure/repositories/device_edit.repository.dart';
import 'package:openapi/api.dart';

void main() {
  test('edits survive a JSON round trip', () {
    final edits = <AssetEdit>[
      CropEdit(CropParameters(x: 1, y: 2, width: 30, height: 40)),
      MirrorEdit(MirrorParameters(axis: MirrorAxis.horizontal)),
      RotateEdit(RotateParameters(angle: 90)),
      MosaicEdit(
        MosaicParameters(
          blockSize: 16,
          strokes: [
            MosaicStroke(mode: MosaicStrokeMode.paint, brushSize: 12, points: [MosaicPoint(x: 5, y: 6)]),
          ],
        ),
      ),
    ];

    final stored = jsonDecode(jsonEncode(edits.map(assetEditToJson).toList())) as List;
    final restored = stored.whereType<Map>().map(assetEditFromJson).nonNulls.toList();

    expect(restored.map((edit) => edit.runtimeType), [CropEdit, MirrorEdit, RotateEdit, MosaicEdit]);
    expect((restored[0] as CropEdit).parameters.width, 30);
    expect((restored[1] as MirrorEdit).parameters.axis, MirrorAxis.horizontal);
    expect((restored[2] as RotateEdit).parameters.angle, 90);
    final mosaic = (restored[3] as MosaicEdit).parameters;
    expect(mosaic.blockSize, 16);
    expect(mosaic.strokes.single.points.single.x, 5);
  });

  test('ignores unknown actions', () {
    expect(assetEditFromJson({'action': 'sharpen', 'parameters': {}}), isNull);
  });
}
