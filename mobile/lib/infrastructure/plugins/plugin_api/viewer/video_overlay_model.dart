import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Shapes of the declarative video overlay layer.
enum VideoOverlayShape {
  rect,
  ellipse,
  roundRect,
  path,
  image,
  text,

  /// Covers the whole frame (ignores `rect`).
  fill;

  static VideoOverlayShape parse(Object? value) {
    for (final shape in values) {
      if (shape.name == value) {
        return shape;
      }
    }
    return switch (value) {
      'oval' || 'circle' => VideoOverlayShape.ellipse,
      'polygon' => VideoOverlayShape.path,
      'emoji' => VideoOverlayShape.text,
      _ => VideoOverlayShape.rect,
    };
  }
}

enum VideoOverlayEasing {
  linear,
  easeIn,
  easeOut,
  easeInOut,

  /// Holds each keyframe until the next one.
  step;

  static VideoOverlayEasing parse(Object? value) {
    for (final easing in values) {
      if (easing.name == value) {
        return easing;
      }
    }
    return VideoOverlayEasing.easeInOut;
  }

  double transform(double t) {
    final x = t.clamp(0.0, 1.0);
    return switch (this) {
      VideoOverlayEasing.linear => x,
      VideoOverlayEasing.easeIn => x * x * x,
      VideoOverlayEasing.easeOut => 1 - math.pow(1 - x, 3).toDouble(),
      VideoOverlayEasing.easeInOut => x < 0.5 ? 4 * x * x * x : 1 - math.pow(-2 * x + 2, 3).toDouble() / 2,
      VideoOverlayEasing.step => x < 1 ? 0 : 1,
    };
  }
}

/// The rect of an item at video time [atMs] (normalized 0–1 to the video frame).
@immutable
class VideoOverlayKeyframe {
  final int atMs;
  final Rect rect;

  const VideoOverlayKeyframe(this.atMs, this.rect);
}

/// One item of the declarative overlay layer.
///
/// Coordinates are normalized to the video frame (0–1, origin top left). The app evaluates every item against its own
/// playback clock each frame: [keyframes] are interpolated with [easing]; outside them (or without them) the rect moves
/// by [velocity] (normalized units per second) from [atMs]. The item is shown while `fromMs <= t <= toMs`
/// (open-ended when null), fading in and out over [fadeMs].
@immutable
class VideoOverlayItem {
  final String id;
  final VideoOverlayShape shape;
  final Rect rect;
  final int? atMs;
  final int? fromMs;
  final int? toMs;

  /// Normalized units per second for `x`, `y` (position) and `width`, `height` (size).
  final Rect velocity;
  final List<VideoOverlayKeyframe> keyframes;
  final VideoOverlayEasing easing;

  /// roundRect: corner radius as a fraction of the item's shorter side.
  final double radius;

  /// path: closed polygon `[x0, y0, x1, y1, ...]`, normalized to the frame at [atMs].
  final List<double> points;

  /// image: a file path (PNG, JPEG, WebP, GIF first frame), drawn into the rect with [fit].
  final String? imagePath;
  final String fit;

  /// text: the text or emoji, [fontSize] as a fraction of the frame height (default: fits the rect height).
  final String? text;
  final double? fontSize;
  final String? fontWeight;

  /// Fill colour (ARGB). Null with [blur] null means no fill.
  final Color? color;

  /// Blurs what is under the shape (sigma in logical pixels) instead of / below the fill.
  final double? blur;
  final Color? strokeColor;
  final double strokeWidth;
  final double opacity;
  final int z;
  final int fadeMs;

  const VideoOverlayItem({
    required this.id,
    this.shape = VideoOverlayShape.rect,
    this.rect = Rect.zero,
    this.atMs,
    this.fromMs,
    this.toMs,
    this.velocity = Rect.zero,
    this.keyframes = const [],
    this.easing = VideoOverlayEasing.easeInOut,
    this.radius = 0.2,
    this.points = const [],
    this.imagePath,
    this.fit = 'contain',
    this.text,
    this.fontSize,
    this.fontWeight,
    this.color,
    this.blur,
    this.strokeColor,
    this.strokeWidth = 0,
    this.opacity = 1,
    this.z = 0,
    this.fadeMs = 0,
  });

  /// Reads an item; returns null when it has no id.
  static VideoOverlayItem? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final id = json['id'];
    if (id == null) {
      return null;
    }
    final keyframes = <VideoOverlayKeyframe>[
      for (final frame in (json['keyframes'] is List ? json['keyframes'] as List : const []).whereType<Map>())
        if (_int(frame['atMs']) != null) VideoOverlayKeyframe(_int(frame['atMs'])!, _rect(frame['rect'] ?? frame)),
    ]..sort((a, b) => a.atMs.compareTo(b.atMs));
    final points = [for (final value in (json['points'] is List ? json['points'] as List : const [])) _double(value)];
    final shape = VideoOverlayShape.parse(json['shape']);
    var rect = json['rect'] != null ? _rect(json['rect']) : (keyframes.isNotEmpty ? keyframes.first.rect : Rect.zero);
    if (shape == VideoOverlayShape.path && json['rect'] == null && points.length >= 4) {
      rect = _bounds(points);
    }
    final image = json['image'];
    return VideoOverlayItem(
      id: '$id',
      shape: shape,
      rect: rect,
      atMs: _int(json['atMs']) ?? (keyframes.isNotEmpty ? keyframes.first.atMs : _int(json['fromMs'])),
      fromMs: _int(json['fromMs']),
      toMs: _int(json['toMs']),
      velocity: _velocity(json['velocity']),
      keyframes: keyframes,
      easing: VideoOverlayEasing.parse(json['easing']),
      radius: _double(json['radius'] ?? 0.2),
      points: points,
      imagePath: image is Map ? image['path'] as String? : (image is String ? image : json['imagePath'] as String?),
      fit: '${json['fit'] ?? 'contain'}',
      text: json['text'] as String?,
      fontSize: json['fontSize'] == null ? null : _double(json['fontSize']),
      fontWeight: json['fontWeight'] as String?,
      color: parseColor(json['color'] ?? json['fill']),
      blur: json['blur'] == null ? (json['fill'] is Map ? _blurOf(json['fill'] as Map) : null) : _double(json['blur']),
      strokeColor: json['stroke'] is Map ? parseColor((json['stroke'] as Map)['color']) : null,
      strokeWidth: json['stroke'] is Map ? _double((json['stroke'] as Map)['width'] ?? 2) : 0,
      opacity: _double(json['opacity'] ?? 1).clamp(0.0, 1.0),
      z: _int(json['z']) ?? 0,
      fadeMs: _int(json['fadeMs']) ?? 0,
    );
  }

  /// Whether the item is shown at video time [t] (milliseconds).
  bool visibleAt(int t) => (fromMs == null || t >= fromMs!) && (toMs == null || t <= toMs!);

  /// Opacity at [t], including the fade in / out.
  double opacityAt(int t) {
    if (!visibleAt(t)) {
      return 0;
    }
    if (fadeMs <= 0) {
      return opacity;
    }
    var factor = 1.0;
    if (fromMs != null) {
      factor = math.min(factor, (t - fromMs!) / fadeMs);
    }
    if (toMs != null) {
      factor = math.min(factor, (toMs! - t) / fadeMs);
    }
    return opacity * factor.clamp(0.0, 1.0);
  }

  /// The normalized rect at video time [t].
  Rect rectAt(int t) {
    if (shape == VideoOverlayShape.fill) {
      return const Rect.fromLTWH(0, 0, 1, 1);
    }
    if (keyframes.isEmpty) {
      return _move(rect, (t - (atMs ?? t)) / 1000);
    }
    final first = keyframes.first;
    if (t <= first.atMs) {
      return keyframes.length == 1 ? _move(first.rect, (t - first.atMs) / 1000) : first.rect;
    }
    for (var i = 0; i < keyframes.length - 1; i++) {
      final a = keyframes[i];
      final b = keyframes[i + 1];
      if (t <= b.atMs) {
        final span = b.atMs - a.atMs;
        final progress = span <= 0 ? 1.0 : easing.transform((t - a.atMs) / span);
        return Rect.lerp(a.rect, b.rect, progress)!;
      }
    }
    final last = keyframes.last;
    return _move(last.rect, (t - last.atMs) / 1000);
  }

  /// [points] (path) moved and scaled along with the rect at [t].
  List<Offset> pointsAt(int t) {
    final base = keyframes.isNotEmpty ? keyframes.first.rect : rect;
    final now = rectAt(t);
    final sx = base.width == 0 ? 1.0 : now.width / base.width;
    final sy = base.height == 0 ? 1.0 : now.height / base.height;
    return [
      for (var i = 0; i + 1 < points.length; i += 2)
        Offset(now.left + (points[i] - base.left) * sx, now.top + (points[i + 1] - base.top) * sy),
    ];
  }

  Rect _move(Rect from, double seconds) {
    if (velocity == Rect.zero || seconds == 0) {
      return from;
    }
    return Rect.fromLTWH(
      from.left + velocity.left * seconds,
      from.top + velocity.top * seconds,
      math.max(0, from.width + velocity.width * seconds),
      math.max(0, from.height + velocity.height * seconds),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'shape': shape.name,
    'rect': _rectJson(rect),
    'atMs': ?atMs,
    'fromMs': ?fromMs,
    'toMs': ?toMs,
    if (velocity != Rect.zero)
      'velocity': {'x': velocity.left, 'y': velocity.top, 'width': velocity.width, 'height': velocity.height},
    if (keyframes.isNotEmpty)
      'keyframes': [
        for (final frame in keyframes) {'atMs': frame.atMs, 'rect': _rectJson(frame.rect)},
      ],
    'easing': easing.name,
    if (shape == VideoOverlayShape.roundRect) 'radius': radius,
    if (points.isNotEmpty) 'points': points,
    if (imagePath != null) 'image': {'path': imagePath},
    if (imagePath != null) 'fit': fit,
    'text': ?text,
    'fontSize': ?fontSize,
    'fontWeight': ?fontWeight,
    if (color != null) 'color': colorToHex(color!),
    'blur': ?blur,
    if (strokeColor != null) 'stroke': {'color': colorToHex(strokeColor!), 'width': strokeWidth},
    'opacity': opacity,
    'z': z,
    if (fadeMs > 0) 'fadeMs': fadeMs,
  };

  static Map<String, double> _rectJson(Rect rect) => {
    'x': rect.left,
    'y': rect.top,
    'width': rect.width,
    'height': rect.height,
  };

  static Rect _rect(Object? json) {
    if (json is List && json.length >= 4) {
      return Rect.fromLTWH(_double(json[0]), _double(json[1]), _double(json[2]), _double(json[3]));
    }
    if (json is! Map) {
      return Rect.zero;
    }
    return Rect.fromLTWH(
      _double(json['x'] ?? json['left']),
      _double(json['y'] ?? json['top']),
      _double(json['width'] ?? json['w']),
      _double(json['height'] ?? json['h']),
    );
  }

  static Rect _velocity(Object? json) {
    if (json is! Map) {
      return Rect.zero;
    }
    return Rect.fromLTWH(
      _double(json['x'] ?? json['dx']),
      _double(json['y'] ?? json['dy']),
      _double(json['width'] ?? json['dw']),
      _double(json['height'] ?? json['dh']),
    );
  }

  static Rect _bounds(List<double> points) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    for (var i = 0; i + 1 < points.length; i += 2) {
      minX = math.min(minX, points[i]);
      maxX = math.max(maxX, points[i]);
      minY = math.min(minY, points[i + 1]);
      maxY = math.max(maxY, points[i + 1]);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static double? _blurOf(Map fill) => fill['blur'] == null ? null : _double(fill['blur']);

  static double _double(Object? value) => switch (value) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s) ?? 0,
    _ => 0,
  };

  static int? _int(Object? value) => switch (value) {
    final num n => n.round(),
    final String s => int.tryParse(s),
    _ => null,
  };
}

/// `#AARRGGBB`, `#RRGGBB`, `0xAARRGGBB`, an int (ARGB) or `[r, g, b]` / `[r, g, b, a]` (0–255).
Color? parseColor(Object? value) {
  switch (value) {
    case final int argb:
      return Color(argb);
    case final String text:
      final hex = text.replaceFirst('#', '').replaceFirst('0x', '');
      final parsed = int.tryParse(hex, radix: 16);
      if (parsed == null) {
        return null;
      }
      return Color(hex.length <= 6 ? 0xFF000000 | parsed : parsed);
    case final List list when list.length >= 3:
      int channel(int i) => (list[i] as num? ?? 255).toInt().clamp(0, 255);
      return Color.fromARGB(list.length >= 4 ? channel(3) : 255, channel(0), channel(1), channel(2));
    default:
      return null;
  }
}

String colorToHex(Color color) => '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// The overlay items of one owner (`<plugin>/<layer>`) for one target.
class VideoOverlayLayerData {
  final String owner;
  final Map<String, VideoOverlayItem> items;

  VideoOverlayLayerData(this.owner, [Map<String, VideoOverlayItem>? items]) : items = items ?? {};
}

/// All declarative overlay items, per target: a video session id, or `asset:<assetId>` for every session of an
/// asset (so a plugin can prepare overlays before the video starts).
class VideoOverlayStore extends ChangeNotifier {
  final _targets = <String, Map<String, VideoOverlayLayerData>>{};

  static String assetTarget(String assetId) => 'asset:$assetId';

  bool get isEmpty => _targets.isEmpty;

  /// Replaces [owner]'s items for [target].
  void set(String target, String owner, Iterable<VideoOverlayItem> items) {
    final layers = _targets.putIfAbsent(target, () => {});
    layers[owner] = VideoOverlayLayerData(owner, {for (final item in items) item.id: item});
    notifyListeners();
  }

  /// Adds or replaces [upsert] and removes [remove] (ids) in [owner]'s items for [target].
  void patch(
    String target,
    String owner, {
    Iterable<VideoOverlayItem> upsert = const [],
    Iterable<String> remove = const [],
  }) {
    final layer = _targets.putIfAbsent(target, () => {}).putIfAbsent(owner, () => VideoOverlayLayerData(owner));
    for (final id in remove) {
      layer.items.remove(id);
    }
    for (final item in upsert) {
      layer.items[item.id] = item;
    }
    notifyListeners();
  }

  /// Removes [owner]'s items for [target] (all targets when null; every owner of the plugin when [owner] ends in `/*`).
  void clear(String owner, {String? target}) {
    bool matches(String key) =>
        owner.endsWith('/*') ? key.startsWith(owner.substring(0, owner.length - 1)) : key == owner;
    var changed = false;
    for (final entry in _targets.entries) {
      if (target != null && entry.key != target) {
        continue;
      }
      final before = entry.value.length;
      entry.value.removeWhere((key, _) => matches(key));
      changed |= entry.value.length != before;
    }
    _targets.removeWhere((_, layers) => layers.isEmpty);
    if (changed) {
      notifyListeners();
    }
  }

  /// Drops everything for [target] (when a session ends).
  void dropTarget(String target) {
    if (_targets.remove(target) != null) {
      notifyListeners();
    }
  }

  /// The items shown for a session of [assetId], sorted by `z`.
  List<VideoOverlayItem> itemsFor(String sessionId, String assetId) {
    final layers = [...?_targets[assetTarget(assetId)]?.values, ...?_targets[sessionId]?.values];
    if (layers.isEmpty) {
      return const [];
    }
    return [for (final layer in layers) ...layer.items.values]..sort((a, b) => a.z.compareTo(b.z));
  }

  bool hasItemsFor(String sessionId, String assetId) =>
      (_targets[sessionId]?.values.any((l) => l.items.isNotEmpty) ?? false) ||
      (_targets[assetTarget(assetId)]?.values.any((l) => l.items.isNotEmpty) ?? false);

  Map<String, dynamic> toJson(String target) => {
    for (final layer in _targets[target]?.values ?? const <VideoOverlayLayerData>[])
      layer.owner: [for (final item in layer.items.values) item.toJson()],
  };
}
