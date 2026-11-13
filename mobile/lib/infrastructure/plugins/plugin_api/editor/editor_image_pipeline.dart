import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_workspace.dart';
import 'package:immich_mobile/utils/asset_edit_renderer.utils.dart';

/// Bakes non-destructive edits (crop, rotate, mirror, mosaic) into a working image of any size.
///
/// Images up to [editorMaxGpuDimension] per side render on the GPU like the regular save; larger ones (tool results
/// such as upscales) render on the CPU in an isolate.
class EditorImagePipeline {
  final CensorEffectBuilder? censorEffects;

  const EditorImagePipeline({this.censorEffects});

  /// Renders [edits] over [image] into a new file of [workspace], encoded as [format] (default: the image's own).
  /// Returns [image] itself when there is nothing to render and it is already in that format.
  Future<EditorWorkingImage> bake(
    EditorWorkingImage image,
    List<AssetEdit> edits,
    EditorImageWorkspace workspace, {
    RenderFormat? format,
    int? generation,
    String name = 'baked',
  }) async {
    final target = format ?? image.renderFormat;
    if (edits.isEmpty && image.normalized && image.mime == _mime(target)) {
      return generation == null ? image : image.withGeneration(generation);
    }

    final bytes = await image.file.readAsBytes();
    final rendered = image.exceedsGpu
        ? await renderLargeAssetEdits(bytes, edits, format: target, censorEffects: censorEffects)
        : await renderAssetEdits(bytes, edits, format: target, censorEffects: censorEffects);
    return workspace.writeEncoded(
      rendered.bytes,
      generation: generation ?? image.generation,
      width: rendered.width,
      height: rendered.height,
      name: name,
    );
  }

  static String _mime(RenderFormat format) => format == RenderFormat.png ? 'image/png' : 'image/jpeg';
}
