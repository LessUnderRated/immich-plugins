import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/infrastructure/plugins/device_workflow_engine.dart';
import 'package:immich_mobile/utils/asset_edit_renderer.utils.dart';

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
    try {
      final data = await grid.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        return null;
      }
      response = await _engine.callPluginMethod(selected.pluginName, selected.methodName, {
        'type': censorStyleType,
        'config': options,
        'data': {
          'width': width,
          'height': height,
          'size': size,
          'grid': {
            'width': grid.width,
            'height': grid.height,
            'cell': cell,
            'rgba': base64Encode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)),
          },
        },
      });
    } finally {
      grid.dispose();
    }

    return response == null ? null : _draw(response, source, width);
  }

  Future<ui.Image> _draw(Map<String, dynamic> response, ui.Image source, int width) async {
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

    final shapes = response['shapes'];
    if (shapes is List) {
      final paint = Paint()
        ..isAntiAlias = false
        ..style = PaintingStyle.fill;
      for (final shape in shapes.whereType<Map>()) {
        final path = _path(shape['points'], scale);
        if (path == null) {
          continue;
        }
        canvas.drawPath(path, paint..color = _color(shape['color']));
      }
    }

    final picture = recorder.endRecording();
    try {
      return await picture.toImage(source.width, source.height);
    } finally {
      picture.dispose();
      overlay?.dispose();
    }
  }

  static Path? _path(Object? points, double scale) {
    if (points is! List || points.length < 6) {
      return null;
    }
    final path = Path()..moveTo((points[0] as num) * scale, (points[1] as num) * scale);
    for (var index = 2; index + 1 < points.length; index += 2) {
      path.lineTo((points[index] as num) * scale, (points[index + 1] as num) * scale);
    }
    return path..close();
  }

  static Color _color(Object? value) {
    if (value is List && value.length >= 3) {
      final alpha = value.length > 3 ? (value[3] as num).toInt() : 255;
      return Color.fromARGB(alpha, (value[0] as num).toInt(), (value[1] as num).toInt(), (value[2] as num).toInt());
    }
    if (value is String && value.startsWith('#') && value.length == 7) {
      return Color(int.parse('ff${value.substring(1)}', radix: 16));
    }
    return const Color(0xFF000000);
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
