import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/image_pipeline.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/video_sessions.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:openapi/api.dart';

/// Where a video can be read from without a player.
typedef VideoFrameSource = ({String? path, String? url, Map<String, String> headers});

/// Options of `image.load(assetId, options)`.
class ImageLoadOptions {
  /// Bounding box to decode into (the image keeps its aspect ratio). Null: [maxSize] on the long side.
  final int? width;
  final int? height;
  final int maxSize;

  /// Video frame time. Null for a photo, or for a video's poster frame.
  final int? timeMs;

  /// `rgba` (raw pixels, row-major, 4 bytes per pixel), `png`, or `jpeg` (video frames only; photos fall back to png).
  final String format;

  /// Decode the original instead of the preview (remote photos).
  final bool original;

  /// Run the image pipeline (`image.preview` / `image.full` hooks) so the result is what the viewer shows.
  final bool processed;

  const ImageLoadOptions({
    this.width,
    this.height,
    this.maxSize = 2048,
    this.timeMs,
    this.format = 'rgba',
    this.original = false,
    this.processed = false,
  });

  factory ImageLoadOptions.fromJson(Object? json) {
    if (json is! Map) {
      return const ImageLoadOptions();
    }
    final size = json['size'];
    int? read(Object? value) => value is num ? value.round() : null;
    return ImageLoadOptions(
      width: size is Map ? read(size['width']) : read(json['width']),
      height: size is Map ? read(size['height']) : read(json['height']),
      maxSize: read(size is num ? size : json['maxSize']) ?? 2048,
      timeMs: read(json['timeMs']),
      format: '${json['format'] ?? 'rgba'}' == 'encoded' ? 'png' : '${json['format'] ?? 'rgba'}',
      original: json['original'] == true,
      processed: json['processed'] == true,
    );
  }

  ui.Size get box => width != null && height != null
      ? ui.Size(width!.toDouble(), height!.toDouble())
      : ui.Size(maxSize.toDouble(), maxSize.toDouble());
}

/// `image.load`: a photo, or a video frame at any time, as a file. The kernel's `regionEditor` node calls it by name.
///
/// Returns `{ "path", "width", "height", "format", "timeMs"? }`. The file is temporary; copy it to keep it.
abstract final class ViewerImageLoad {
  static Future<Map<String, dynamic>> load(
    BaseAsset asset,
    ImageLoadOptions options, {
    required Future<VideoFrameSource> Function(BaseAsset asset) videoSource,
  }) async {
    if (asset.isVideo && options.timeMs != null) {
      return _videoFrame(asset, options, videoSource);
    }
    final image = await _decodePhoto(asset, options);
    try {
      var shown = image;
      if (options.processed) {
        final stage = options.original ? ImageStage.full : ImageStage.preview;
        shown = await ImagePipeline.applyToImage(ImagePipelineTarget(stage, ImageSubject.of(asset)), image) ?? image;
      }
      try {
        return await _write(shown, options.format);
      } finally {
        if (!identical(shown, image)) {
          shown.dispose();
        }
      }
    } finally {
      image.dispose();
    }
  }

  static Future<Map<String, dynamic>> _videoFrame(
    BaseAsset asset,
    ImageLoadOptions options,
    Future<VideoFrameSource> Function(BaseAsset asset) videoSource,
  ) async {
    final source = await videoSource(asset);
    final box = options.box;
    final size = _fit(asset, box);
    return PluginVideoChannel.extractFrame(
      path: source.path,
      url: source.url,
      headers: source.headers,
      localId: asset.localId,
      timeMs: options.timeMs!,
      width: size?.width.round(),
      height: size?.height.round(),
      format: options.format,
    );
  }

  static ui.Size? _fit(BaseAsset asset, ui.Size box) {
    final width = asset.width;
    final height = asset.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    final scale = math.min(1.0, math.min(box.width / width, box.height / height));
    return ui.Size(math.max(1, width * scale), math.max(1, height * scale));
  }

  static Future<ui.Image> _decodePhoto(BaseAsset asset, ImageLoadOptions options) async {
    final box = options.box;
    final ImageRequest request;
    final localId = asset.localId;
    if (localId != null && (asset is LocalAsset || !asset.isEdited)) {
      request = LocalImageRequest(localId: localId, size: options.original ? ui.Size.zero : box, assetType: asset.type);
    } else {
      final remoteId = asset.remoteId;
      if (remoteId == null) {
        throw StateError('Asset ${asset.id} has no image');
      }
      request = RemoteImageRequest(
        uri: options.original
            ? getOriginalUrlForRemoteId(remoteId)
            : getThumbnailUrlForRemoteId(remoteId, type: AssetMediaSize.preview),
        decodeSize: options.original ? null : box,
      );
    }
    final info = await request.load(PaintingBinding.instance.instantiateImageCodecWithSize);
    if (info == null) {
      throw StateError('Could not decode ${asset.id}');
    }
    final image = info.image.clone();
    info.dispose();
    return _downscale(image, box);
  }

  /// Fits [image] into [box] when it is larger (platform decoders may return a bigger image than asked for).
  static Future<ui.Image> _downscale(ui.Image image, ui.Size box) async {
    final scale = math.min(box.width / image.width, box.height / image.height);
    if (scale >= 1) {
      return image;
    }
    final width = math.max(1, (image.width * scale).round());
    final height = math.max(1, (image.height * scale).round());
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
      image.dispose();
    }
  }

  static Future<Map<String, dynamic>> _write(ui.Image image, String format) async {
    if (format == 'rgba') {
      final file = await ImagePipeline.writeRgba(image, prefix: 'load');
      if (file == null) {
        throw StateError('Could not read image pixels');
      }
      return {'path': file.path, 'width': image.width, 'height': image.height, 'format': 'rgba'};
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('Could not encode image');
    }
    final file = await ImagePipeline.tempFile('load', 'png');
    await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    return {'path': file.path, 'width': image.width, 'height': image.height, 'format': 'png'};
  }
}
