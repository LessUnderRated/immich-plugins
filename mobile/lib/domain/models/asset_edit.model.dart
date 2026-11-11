import "package:openapi/api.dart" show CropParameters, MirrorParameters, MosaicParameters, RotateParameters;

enum AssetEditAction { rotate, crop, mirror, other, mosaic }

sealed class AssetEdit {
  const AssetEdit();
}

class CropEdit extends AssetEdit {
  final CropParameters parameters;

  const CropEdit(this.parameters);
}

class RotateEdit extends AssetEdit {
  final RotateParameters parameters;

  const RotateEdit(this.parameters);
}

class MirrorEdit extends AssetEdit {
  final MirrorParameters parameters;

  const MirrorEdit(this.parameters);
}

class MosaicEdit extends AssetEdit {
  final MosaicParameters parameters;

  const MosaicEdit(this.parameters);
}
