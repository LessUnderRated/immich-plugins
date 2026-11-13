import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/utils/editor.utils.dart';
import 'package:immich_mobile/utils/mosaic.utils.dart';
import 'package:openapi/api.dart' show MirrorAxis, MirrorParameters, RotateParameters;

/// The non-destructive edits of [state], in pixels of an image of [width] x [height] (default: the state's original
/// size). Crop and mosaic are stored normalized, so the same state can be rendered on an image of another size.
List<AssetEdit> editorStateToEdits(EditorState state, {int? width, int? height}) {
  final imageWidth = width ?? state.originalWidth;
  final imageHeight = height ?? state.originalHeight;
  final cropParameters = convertRectToCropParameters(state.crop, imageWidth, imageHeight);
  final edits = <AssetEdit>[];

  if (cropParameters.width != imageWidth || cropParameters.height != imageHeight) {
    edits.add(CropEdit(cropParameters));
  }

  if (state.flipHorizontal) {
    edits.add(MirrorEdit(MirrorParameters(axis: MirrorAxis.horizontal)));
  }

  if (state.flipVertical) {
    edits.add(MirrorEdit(MirrorParameters(axis: MirrorAxis.vertical)));
  }

  final normalizedRotation = (state.rotationAngle % 360 + 360) % 360;
  if (normalizedRotation != 0) {
    edits.add(RotateEdit(RotateParameters(angle: normalizedRotation)));
  }

  final mosaicParameters = mosaicToParameters(state.mosaicStrokes, state.mosaicBlockSize, imageWidth, imageHeight);
  if (mosaicParameters != null) {
    edits.add(MosaicEdit(mosaicParameters));
  }

  return edits;
}

/// JSON summary of the edits in [state] (normalized values), as used in editor events and `editor.state`.
Map<String, dynamic> editorStateToJson(EditorState state) => {
  'width': state.originalWidth,
  'height': state.originalHeight,
  'crop': {'x': state.crop.left, 'y': state.crop.top, 'width': state.crop.width, 'height': state.crop.height},
  'rotation': (state.rotationAngle % 360 + 360) % 360,
  'flipHorizontal': state.flipHorizontal,
  'flipVertical': state.flipVertical,
  'aspectRatio': state.aspectRatio.name,
  'mosaicStrokes': state.mosaicStrokes.length,
  'hasEdits': state.hasEdits,
  'hasUnsavedEdits': state.hasUnsavedEdits,
  'isApplyingEdits': state.isApplyingEdits,
};
