import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/infrastructure/plugins/device_workflow_engine.dart';
import 'package:immich_mobile/utils/asset_edit_renderer.utils.dart';
import 'package:immich_mobile/utils/censor_geometry.dart';

const censorStyleType = 'CensorStyleV1';

class CensorStyleOption {
  final String pluginName;
  final String methodName;
  final String title;
  final String description;
  final Map<String, dynamic> schema;

  const CensorStyleOption({
    required this.pluginName,
    required this.methodName,
    required this.title,
    required this.description,
    required this.schema,
  });

  String get key => '$pluginName#$methodName';

  bool get hasOptions => schema['properties'] is Map && (schema['properties'] as Map).isNotEmpty;
}

class CensorStyles {
  final DeviceWorkflowEngine _engine;

  const CensorStyles(this._engine);

  Future<List<CensorStyleOption>> list() async => [
    for (final (plugin, method) in await _engine.censorStyleMethods())
      CensorStyleOption(
        pluginName: plugin.name,
        methodName: method.name,
        title: method.title,
        description: method.description,
        schema: method.schema,
      ),
  ];

  Future<ui.Image?> render(
    String? style,
    Map<String, Object?> options,
    ui.Image source,
    int size,
    int width,
    int height,
  ) async {
    final styles = await list();
    final selected = styles.firstWhereOrNull((option) => option.key == style) ?? styles.firstOrNull;
    if (selected == null) {
      return null;
    }

    final cell = max(1, size ~/ 2);
    final grid = await downsampleImage(source, cell, width: width, height: height);
    final Map<String, dynamic>? response;
    final GridSampler sampler;
    try {
      final data = await grid.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        return null;
      }
      final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      sampler = GridSampler(rgba: rgba, width: grid.width, height: grid.height, cell: cell);
      response = await _engine.callPluginMethod(selected.pluginName, selected.methodName, {
        'type': censorStyleType,
        'config': options,
        'data': {
          'width': width,
          'height': height,
          'size': size,
          'grid': {'width': grid.width, 'height': grid.height, 'cell': cell, 'rgba': base64Encode(rgba)},
        },
      });
    } finally {
      grid.dispose();
    }

    return response == null ? null : _draw(response, source, width, height, sampler);
  }

  Future<ui.Image> _draw(
    Map<String, dynamic> response,
    ui.Image source,
    int width,
    int height,
    GridSampler sampler,
  ) async {
    final scale = source.width / width;
    final bounds = Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble());
    final overlay = await _decodeImage(response['image']);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..drawImage(source, Offset.zero, Paint());

    final blur = response['blur'];
    if (blur is num && blur > 0) {
      final sigma = blur * scale;
      canvas.drawImageRect(
        source,
        bounds,
        bounds,
        Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp),
      );
    }

    if (overlay != null) {
      final smooth = (response['image'] as Map)['smooth'] == true;
      canvas.drawImageRect(
        overlay,
        Rect.fromLTWH(0, 0, overlay.width.toDouble(), overlay.height.toDouble()),
        bounds,
        Paint()..filterQuality = smooth ? FilterQuality.medium : FilterQuality.none,
      );
    }

    final area = Size(width.toDouble(), height.toDouble());
    final polygons = [
      ...buildCensorTiles(response['tiles'], area, sampler),
      ...buildCensorCells(response['cells'], area, sampler),
      ...buildCensorShapes(response['shapes'], sampler),
    ];
    final paint = Paint()
      ..isAntiAlias = false
      ..style = PaintingStyle.fill;
    for (final polygon in polygons) {
      final path = Path()..moveTo(polygon.points.first.dx * scale, polygon.points.first.dy * scale);
      for (final point in polygon.points.skip(1)) {
        path.lineTo(point.dx * scale, point.dy * scale);
      }
      canvas.drawPath(path..close(), paint..color = polygon.color);
    }

    final picture = recorder.endRecording();
    try {
      return await picture.toImage(source.width, source.height);
    } finally {
      picture.dispose();
      overlay?.dispose();
    }
  }

  static Future<ui.Image?> _decodeImage(Object? image) async {
    if (image is! Map) {
      return null;
    }
    final width = image['width'];
    final height = image['height'];
    final rgba = image['rgba'];
    if (width is! int || height is! int || rgba is! String) {
      return null;
    }
    final pixels = base64Decode(rgba);
    if (pixels.length != width * height * 4) {
      return null;
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(pixels));
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }
}
