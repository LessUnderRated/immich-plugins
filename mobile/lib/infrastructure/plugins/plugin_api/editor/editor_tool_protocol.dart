/// `EditorToolV1`: the call protocol between the image editor and plugin tools. See `docs/plugins/editor.md`.
library;

import 'package:immich_mobile/infrastructure/plugins/plugin_api/editor/editor_ids.dart';

/// Largest image (in pixels) the editor accepts from a tool and can still crop, censor and save.
const editorMaxImagePixels = 64 * 1024 * 1024;

/// Images with a side above this are rendered on the CPU instead of the GPU (texture size limit).
const editorMaxGpuDimension = 8192;

/// Longest side of the image the editor decodes for display; the full image is used for rendering and saving.
const editorDisplayMaxDimension = 4096;

/// Default longest side of the source handed to the `preview` phase.
const editorDefaultPreviewSize = 1024;

enum EditorToolPhase {
  /// The tool was selected: return its panel (`ui` tree or native `view`).
  panel,

  /// Render a quick preview of the current panel state on a downscaled source.
  preview,

  /// Render the result on the full source. The result replaces the editor's working image.
  apply,

  /// The user cancelled a running `apply` (sent on a separate call while `apply` is still running).
  cancel,

  /// The tool was deselected or the editor closed: release models and buffers.
  dispose;

  static EditorToolPhase? parse(Object? value) => values.where((phase) => phase.name == value).firstOrNull;
}

/// How an image travels between the editor and a plugin: a file path plus its layout.
enum EditorImageFormat {
  /// Raw RGBA8888, `width * height * 4` bytes, row-major, no padding, non-premultiplied alpha.
  rgba,

  /// An encoded PNG, JPEG or WebP file (no EXIF orientation: pixels as displayed).
  encoded;

  static EditorImageFormat? parse(Object? value) => switch (value) {
    'rgba' => EditorImageFormat.rgba,
    'encoded' || 'png' || 'jpeg' || 'jpg' || 'webp' => EditorImageFormat.encoded,
    _ => null,
  };
}

/// Format a tool wants its source in (`params.source` in the tool contribution).
enum EditorSourceFormat {
  rgba('rgba'),
  png('image/png'),
  jpeg('image/jpeg');

  final String mime;

  const EditorSourceFormat(this.mime);

  EditorImageFormat get transport => this == rgba ? EditorImageFormat.rgba : EditorImageFormat.encoded;

  static EditorSourceFormat parse(Object? value) => switch (value) {
    'png' || 'encoded' => EditorSourceFormat.png,
    'jpeg' || 'jpg' => EditorSourceFormat.jpeg,
    _ => EditorSourceFormat.rgba,
  };
}

class EditorToolException implements Exception {
  final String message;

  const EditorToolException(this.message);

  @override
  String toString() => message;
}

/// An image file handed to or returned by a plugin.
class EditorImageRef {
  final String path;

  /// 0 when unknown (encoded results may omit the size; the editor then reads it from the file header).
  final int width;
  final int height;
  final EditorImageFormat format;
  final String? mime;

  const EditorImageRef({
    required this.path,
    required this.width,
    required this.height,
    required this.format,
    this.mime,
  });

  int get pixels => width * height;

  bool get hasSize => width > 0 && height > 0;

  /// Parses `{ "path", "width", "height", "format": "rgba" | "encoded" }`. Returns null when [json] is not an image.
  static EditorImageRef? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final path = json['path'];
    if (path is! String || path.isEmpty) {
      return null;
    }
    final format =
        EditorImageFormat.parse(json['format']) ??
        (json['rgba'] == true ? EditorImageFormat.rgba : EditorImageFormat.encoded);
    final width = (json['width'] as num?)?.toInt() ?? 0;
    final height = (json['height'] as num?)?.toInt() ?? 0;
    if (format == EditorImageFormat.rgba && (width <= 0 || height <= 0)) {
      throw const EditorToolException('An rgba image needs width and height');
    }
    return EditorImageRef(path: path, width: width, height: height, format: format, mime: json['mime'] as String?);
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'width': width,
    'height': height,
    'format': format.name,
    if (mime != null) 'mime': mime,
  };
}

/// Limits the editor enforces on tool results, sent with every request so tools can adapt (e.g. pick a scale).
class EditorToolLimits {
  final int maxPixels;
  final int maxDimension;

  const EditorToolLimits({this.maxPixels = editorMaxImagePixels, this.maxDimension = 65535});

  void check(int width, int height) {
    if (width <= 0 || height <= 0) {
      throw const EditorToolException('The tool returned an empty image');
    }
    if (width > maxDimension || height > maxDimension || width * height > maxPixels) {
      final megapixels = (width * height / 1000000).toStringAsFixed(1);
      final limit = (maxPixels / 1000000).toStringAsFixed(0);
      throw EditorToolException('The result is too large ($width x $height, $megapixels MP; limit $limit MP)');
    }
  }

  Map<String, dynamic> toJson() => {'maxPixels': maxPixels, 'maxDimension': maxDimension};
}

/// Normalized (0-1) rectangle of the source covered by a preview image.
class EditorRegion {
  final double x;
  final double y;
  final double width;
  final double height;

  const EditorRegion(this.x, this.y, this.width, this.height);

  static const full = EditorRegion(0, 0, 1, 1);

  static EditorRegion? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    double value(String key, double fallback) => ((json[key] as num?)?.toDouble() ?? fallback).clamp(0.0, 1.0);
    final x = value('x', 0);
    final y = value('y', 0);
    final width = value('width', 1 - x).clamp(0.0, 1 - x);
    final height = value('height', 1 - y).clamp(0.0, 1 - y);
    return width <= 0 || height <= 0 ? null : EditorRegion(x, y, width, height);
  }

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'width': width, 'height': height};
}

/// The `data` of an `EditorToolV1` call.
class EditorToolRequest {
  final EditorToolPhase phase;

  /// The plugin's own tool id (`contributes.tools[].id`).
  final String tool;

  /// Editor session id: stable while the editor stays open, new for every opening.
  final String session;

  /// Increases every time the working image is replaced (tool applied, undo).
  final int generation;

  /// Size of the editor's current working image (sent in every phase as `image`).
  final int imageWidth;
  final int imageHeight;

  /// The file to process (`preview` and `apply`). Read-only: never modify or delete it.
  final EditorImageRef? source;
  final Map<String, dynamic> state;
  final Map<String, dynamic>? asset;
  final int? previewMaxSize;
  final String? taskId;

  /// Folder to write results into (`output.dir`).
  final String? outputDir;
  final EditorToolLimits limits;
  final Map<String, dynamic> params;

  const EditorToolRequest({
    required this.phase,
    required this.tool,
    required this.session,
    required this.generation,
    this.imageWidth = 0,
    this.imageHeight = 0,
    this.source,
    this.state = const {},
    this.asset,
    this.previewMaxSize,
    this.taskId,
    this.outputDir,
    this.limits = const EditorToolLimits(),
    this.params = const {},
  });

  Map<String, dynamic> toJson() => {
    'phase': phase.name,
    'tool': tool,
    'session': session,
    'generation': generation,
    'image': {'width': imageWidth, 'height': imageHeight},
    if (source != null) 'source': source!.toJson(),
    'state': state,
    if (asset != null) 'asset': asset,
    if (previewMaxSize != null) 'preview': {'maxSize': previewMaxSize},
    if (taskId != null) 'task': {'id': taskId},
    if (outputDir != null) 'output': {'dir': outputDir},
    'limits': limits.toJson(),
    if (params.isNotEmpty) 'params': params,
  };

  /// Full plugin input for direct engine calls (`{ type, config, data }`); the kernel builds this itself.
  Map<String, dynamic> toInput({Map<String, dynamic> config = const {}}) => {
    'type': EditorPluginIds.toolCallType,
    'config': config,
    'data': toJson(),
  };
}

/// A plugin's answer to an `EditorToolV1` call. Every field is optional.
class EditorToolResponse {
  /// Panel content as a JSON UI tree.
  final Map<String, dynamic>? ui;

  /// Panel content as a native view type (`ImmichViewPlugin.createView`), with [viewParams] and [viewHeight].
  final String? view;
  final Map<String, dynamic> viewParams;
  final double? viewHeight;

  /// Panel input values (replaces the current values).
  final Map<String, dynamic>? state;

  /// Preview or apply result.
  final EditorImageRef? image;

  /// Part of the source the preview covers (default: all of it).
  final EditorRegion? region;

  /// The tool has nothing to change: the working image stays as it is.
  final bool unchanged;

  /// The result arrives later through the `editor.applyImage` host function (with the request's task id).
  final bool pending;

  final String? title;
  final String? applyLabel;
  final String? message;
  final List<Map<String, dynamic>> actions;

  const EditorToolResponse({
    this.ui,
    this.view,
    this.viewParams = const {},
    this.viewHeight,
    this.state,
    this.image,
    this.region,
    this.unchanged = false,
    this.pending = false,
    this.title,
    this.applyLabel,
    this.message,
    this.actions = const [],
  });

  static const empty = EditorToolResponse();

  factory EditorToolResponse.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return empty;
    }
    final ui = json['ui'];
    final state = json['state'];
    final viewParams = json['params'];
    final actions = json['actions'];
    return EditorToolResponse(
      ui: ui is Map ? Map<String, dynamic>.from(ui) : null,
      view: json['view'] is String ? json['view'] as String : null,
      viewParams: viewParams is Map ? Map<String, dynamic>.from(viewParams) : const {},
      viewHeight: (json['height'] as num?)?.toDouble(),
      state: state is Map ? Map<String, dynamic>.from(state) : null,
      image: EditorImageRef.fromJson(json['image']),
      region: EditorRegion.fromJson(json['region']),
      unchanged: json['unchanged'] == true,
      pending: json['pending'] == true,
      title: json['title'] as String?,
      applyLabel: json['applyLabel'] as String?,
      message: json['message'] as String?,
      actions: actions is List ? actions.whereType<Map>().map(Map<String, dynamic>.from).toList() : const [],
    );
  }

  bool get hasPanel => ui != null || view != null;
}
