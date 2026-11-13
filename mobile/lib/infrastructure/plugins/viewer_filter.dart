import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart' show AssetType;
import 'package:immich_mobile/infrastructure/plugins/censor_styles.dart';
import 'package:immich_mobile/infrastructure/plugins/device_workflow_engine.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/image_pipeline.dart';
import 'package:immich_mobile/infrastructure/repositories/device_edit.repository.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart' show AssetEntity;

const viewerFilterType = 'ViewerFilterV1';
const _maxPhotoSide = 2048;

class CensorRegion {
  final Rect rect;
  final bool ellipse;

  const CensorRegion(this.rect, {this.ellipse = false});

  static List<CensorRegion> parse(Object? regions) => [
    for (final region in (regions is List ? regions : const []).whereType<Map>())
      CensorRegion(
        Rect.fromLTWH(
          (region['x'] as num? ?? 0).toDouble(),
          (region['y'] as num? ?? 0).toDouble(),
          (region['width'] as num? ?? 0).toDouble(),
          (region['height'] as num? ?? 0).toDouble(),
        ),
        ellipse: region['shape'] == 'ellipse',
      ),
  ].where((region) => region.rect.width > 0 && region.rect.height > 0).toList();
}

class VideoCensorFrame {
  final int timeMs;
  final List<CensorRegion> regions;

  const VideoCensorFrame(this.timeMs, this.regions);
}

class ViewerFilter {
  final DeviceWorkflowEngine _engine;
  final DeviceEditRepository _edits;
  final CensorStyles _styles;

  const ViewerFilter(this._engine, this._edits, this._styles);

  Future<bool> isAvailable() async => (await _engine.viewerFilterMethods()).isNotEmpty;

  Future<Map<String, dynamic>> schema() async => (await _engine.viewerFilterMethods()).firstOrNull?.$2.schema ?? {};

  Future<Map<String, dynamic>?> _call(Map<String, dynamic> config, Map<String, dynamic> data) async {
    final method = (await _engine.viewerFilterMethods()).firstOrNull;
    if (method == null) {
      return null;
    }
    return _engine.callPluginMethod(method.$1.name, method.$2.name, {
      'type': viewerFilterType,
      'config': config,
      'data': data,
    });
  }

  Future<ui.Image?> censorPhoto(String assetId, Map<String, dynamic> config) async {
    final bytes = await _edits.readCurrent(assetId);
    if (bytes == null) {
      return null;
    }

    return censorImage(await _decode(bytes), assetId, config);
  }

  /// Runs the `ViewerFilterV1` plugin on decoded pixels and composites its regions. Takes ownership of [image].
  /// Returns null when nothing needs censoring.
  Future<ui.Image?> censorImage(ui.Image image, String assetId, Map<String, dynamic> config) async {
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (pixels == null) {
      image.dispose();
      return null;
    }

    final file = File(
      p.join((await getTemporaryDirectory()).path, 'viewer-${DateTime.now().microsecondsSinceEpoch}.rgba'),
    );
    try {
      await file.writeAsBytes(pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes), flush: true);
      final response = await _call(config, {
        'kind': 'image',
        'asset': {'id': assetId},
        'source': {'path': file.path, 'width': image.width, 'height': image.height, 'format': 'rgba'},
      });
      final regions = CensorRegion.parse(response?['regions']);
      if (response == null || regions.isEmpty) {
        image.dispose();
        return null;
      }
      return await _composite(image, regions, response);
    } finally {
      if (file.existsSync()) {
        await file.delete();
      }
    }
  }

  Future<List<VideoCensorFrame>> analyzeVideo(
    String assetId,
    Map<String, dynamic> config, {
    required int fromMs,
    required int toMs,
    required int stepMs,
  }) async {
    final entity = await AssetEntity.fromId(assetId);
    final file = await entity?.originFile;
    if (file == null) {
      return const [];
    }
    final response = await _call(config, {
      'kind': 'video',
      'asset': {'id': assetId},
      'source': {'path': file.path},
      'fromMs': fromMs,
      'toMs': toMs,
      'stepMs': stepMs,
    });
    final frames = response?['frames'];
    return [
      for (final frame in (frames is List ? frames : const []).whereType<Map>())
        VideoCensorFrame((frame['timeMs'] as num? ?? 0).toInt(), CensorRegion.parse(frame['regions'])),
    ]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  }

  static Future<ui.Image> _decode(List<int> bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(bytes));
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longest = max(descriptor.width, descriptor.height);
    final scale = longest > _maxPhotoSide ? _maxPhotoSide / longest : 1.0;
    final codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * scale).round(),
      targetHeight: (descriptor.height * scale).round(),
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  Future<ui.Image> _composite(ui.Image image, List<CensorRegion> regions, Map<String, dynamic> response) async {
    final width = image.width;
    final height = image.height;
    final fraction = (response['size'] as num?)?.toDouble() ?? 0.04;
    final size = max(4, (min(width, height) * fraction).round());
    final options = response['styleOptions'] is Map
        ? Map<String, Object?>.from(response['styleOptions'] as Map)
        : const <String, Object?>{};
    final effect = await _styles.render(response['style'] as String?, options, image, size, width, height);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..drawImage(image, Offset.zero, Paint());
    for (final region in regions) {
      final rect = Rect.fromLTWH(
        region.rect.left * width,
        region.rect.top * height,
        region.rect.width * width,
        region.rect.height * height,
      );
      canvas.save();
      region.ellipse ? canvas.clipPath(Path()..addOval(rect)) : canvas.clipRect(rect);
      if (effect != null) {
        canvas.drawImage(effect, Offset.zero, Paint());
      } else {
        canvas.drawRect(rect, Paint()..color = const Color(0xFF000000));
      }
      canvas.restore();
    }

    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
      effect?.dispose();
      image.dispose();
    }
  }
}

/// The viewer censor shield as an image pipeline transformer (`image.preview` / `image.full`), so `ViewerFilterV1`
/// plugins keep working on top of the generic pipeline: every screen-sized image of a local asset is censored while
/// [isEnabled] is true. Registered with `ImagePipeline.addTransformer` by the viewer plugin API (phase B).
class ViewerFilterTransformer implements ImageTransformer {
  final ViewerFilter filter;
  final bool Function() isEnabled;
  final Map<String, dynamic> Function() config;

  const ViewerFilterTransformer({required this.filter, required this.isEnabled, required this.config});

  @override
  String get id => 'viewer.censor';

  @override
  String get signature => '${isEnabled()}:${jsonEncode(config())}';

  @override
  bool appliesTo(ImageStage stage, ImageSubject subject) =>
      stage != ImageStage.thumbnail && subject.type == AssetType.image && isEnabled() && subject.localId != null;

  @override
  Future<ui.Image?> transform(ImageStage stage, ImageSubject subject, ui.Image image) =>
      filter.censorImage(image.clone(), subject.localId!, config());
}
