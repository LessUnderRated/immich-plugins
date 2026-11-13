/// Plugin-provided map content: markers, polylines and areas with tap actions, drawn on the app's map.
///
/// Plugins set layers with the `map.layers.set` host function (`docs/plugins/library.md`, "Map layers"); the map
/// page renders every visible layer as one GeoJSON source with circle, line, fill and label style layers, and
/// reports taps on its features to the owning plugin.
library;

/// One marker, polyline or area of a plugin layer.
class MapPluginFeature {
  /// `point`, `line` or `polygon`.
  final String kind;
  final String id;

  /// `[lat, lng]` pairs: one for a point, the path of a line, the outer ring of a polygon.
  final List<List<double>> points;

  /// Inner rings (holes) of a polygon.
  final List<List<List<double>>> holes;

  /// Style: `color`, `opacity`, `radius`, `width`, `outlineColor`, `label` (all optional).
  final Map<String, dynamic> style;

  /// What a tap does: `{ "method", "params"? }` (calls the plugin) or `{ "command": {...} }`. Falls back to the
  /// layer's action.
  final Map<String, dynamic>? action;

  /// Plugin data passed back on tap.
  final Object? data;

  const MapPluginFeature({
    required this.kind,
    required this.id,
    required this.points,
    this.holes = const [],
    this.style = const {},
    this.action,
    this.data,
  });

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'id': id,
    'points': points,
    if (holes.isNotEmpty) 'holes': holes,
    ...style,
    if (action != null) 'action': action,
    if (data != null) 'data': data,
  };
}

/// A plugin's named group of map features.
class MapPluginLayer {
  final String plugin;
  final String id;
  final List<MapPluginFeature> features;
  final bool visible;
  final double? minZoom;
  final double? maxZoom;

  /// Default tap action of the layer's features.
  final Map<String, dynamic>? action;

  const MapPluginLayer({
    required this.plugin,
    required this.id,
    required this.features,
    this.visible = true,
    this.minZoom,
    this.maxZoom,
    this.action,
  });

  /// The key of this layer: `<plugin>/<id>`.
  String get key => '$plugin/$id';

  /// Id of the GeoJSON source the map uses for this layer (letters, digits, `.`, `-`, `_` only).
  String get sourceId => 'plugin.${_safe(plugin)}.${_safe(id)}';

  static String _safe(String value) => value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  MapPluginFeature? feature(String id) {
    for (final feature in features) {
      if (feature.id == id) {
        return feature;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'plugin': plugin,
    'id': id,
    'visible': visible,
    if (minZoom != null) 'minZoom': minZoom,
    if (maxZoom != null) 'maxZoom': maxZoom,
    if (action != null) 'action': action,
    'markers': [
      for (final f in features)
        if (f.kind == 'point') f.toJson(),
    ],
    'polylines': [
      for (final f in features)
        if (f.kind == 'line') f.toJson(),
    ],
    'areas': [
      for (final f in features)
        if (f.kind == 'polygon') f.toJson(),
    ],
  };

  /// Reads `{ "markers": [...], "polylines": [...], "areas": [...], "visible"?, "minZoom"?, "maxZoom"?, "action"? }`.
  /// Malformed features are skipped.
  factory MapPluginLayer.fromJson(String plugin, String id, Map<String, dynamic> json) {
    final features = <MapPluginFeature>[];
    var index = 0;

    String featureId(Map item) => item['id'] == null ? '${index++}' : '${item['id']}';

    for (final item in _maps(json['markers'])) {
      final point = _point(item) ?? (item['point'] == null ? null : _point(item['point']));
      if (point != null) {
        features.add(_feature('point', featureId(item), [point], item));
      }
    }
    for (final item in _maps(json['polylines'])) {
      final points = _path(item['points']);
      if (points.length >= 2) {
        features.add(_feature('line', featureId(item), points, item));
      }
    }
    for (final item in _maps(json['areas'])) {
      final rings = item['rings'] is List
          ? [for (final ring in item['rings'] as List) _path(ring)]
          : [_path(item['points'])];
      final outer = rings.isEmpty ? const <List<double>>[] : rings.first;
      if (outer.length >= 3) {
        features.add(
          _feature(
            'polygon',
            featureId(item),
            outer,
            item,
            holes: [
              for (final ring in rings.skip(1))
                if (ring.length >= 3) ring,
            ],
          ),
        );
      }
    }

    return MapPluginLayer(
      plugin: plugin,
      id: id,
      features: features,
      visible: json['visible'] != false,
      minZoom: _double(json['minZoom']),
      maxZoom: _double(json['maxZoom']),
      action: json['action'] is Map ? Map<String, dynamic>.from(json['action'] as Map) : null,
    );
  }

  static const _styleKeys = {'color', 'opacity', 'radius', 'width', 'outlineColor', 'label', 'labelColor'};

  static MapPluginFeature _feature(
    String kind,
    String id,
    List<List<double>> points,
    Map item, {
    List<List<List<double>>> holes = const [],
  }) => MapPluginFeature(
    kind: kind,
    id: id,
    points: points,
    holes: holes,
    style: {
      for (final key in _styleKeys)
        if (item[key] != null) key: item[key],
    },
    action: item['action'] is Map ? Map<String, dynamic>.from(item['action'] as Map) : null,
    data: item['data'],
  );

  static Iterable<Map> _maps(Object? value) => value is List ? value.whereType<Map>() : const [];

  static double? _double(Object? value) => switch (value) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s),
    _ => null,
  };

  /// `{ "lat", "lng" }`, `{ "latitude", "longitude" }` or `[lat, lng]`.
  static List<double>? _point(Object? value) {
    if (value is List && value.length >= 2) {
      final lat = _double(value[0]);
      final lng = _double(value[1]);
      return lat == null || lng == null ? null : [lat, lng];
    }
    if (value is Map) {
      final lat = _double(value['lat'] ?? value['latitude']);
      final lng = _double(value['lng'] ?? value['lon'] ?? value['longitude']);
      return lat == null || lng == null ? null : [lat, lng];
    }
    return null;
  }

  static List<List<double>> _path(Object? value) =>
      value is List ? [for (final point in value) ?_point(point)] : const [];
}

/// Builds the MapLibre GeoJSON and style properties of plugin layers.
abstract final class MapPluginGeoJson {
  static const defaultColor = '#FF4250AF';

  static List<double> _lngLat(List<double> point) => [point[1], point[0]];

  static Map<String, dynamic> source(MapPluginLayer layer) => {
    'type': 'FeatureCollection',
    'features': [for (final feature in layer.features) _geoJsonFeature(feature)],
  };

  static Map<String, dynamic> _geoJsonFeature(MapPluginFeature feature) {
    final geometry = switch (feature.kind) {
      'point' => {'type': 'Point', 'coordinates': _lngLat(feature.points.first)},
      'line' => {
        'type': 'LineString',
        'coordinates': [for (final point in feature.points) _lngLat(point)],
      },
      _ => {
        'type': 'Polygon',
        'coordinates': [_ring(feature.points), for (final hole in feature.holes) _ring(hole)],
      },
    };
    final style = feature.style;
    return {
      'type': 'Feature',
      'id': feature.id,
      'geometry': geometry,
      'properties': {
        'id': feature.id,
        'color': cssColor(style['color']) ?? cssColor(defaultColor),
        'outlineColor': cssColor(style['outlineColor']) ?? cssColor(style['color']) ?? cssColor(defaultColor),
        'labelColor': cssColor(style['labelColor']) ?? '#000000',
        'opacity': _number(style['opacity']) ?? (feature.kind == 'polygon' ? 0.3 : 0.9),
        'radius': _number(style['radius']) ?? 8,
        'width': _number(style['width']) ?? 3,
        if (style['label'] != null) 'label': '${style['label']}',
      },
    };
  }

  static List<List<double>> _ring(List<List<double>> points) {
    final ring = [for (final point in points) _lngLat(point)];
    if (ring.isNotEmpty && (ring.first[0] != ring.last[0] || ring.first[1] != ring.last[1])) {
      ring.add(ring.first);
    }
    return ring;
  }

  static num? _number(Object? value) => switch (value) {
    final num n => n,
    final String s => num.tryParse(s),
    _ => null,
  };

  /// `#AARRGGBB`, `#RRGGBB` or any CSS color MapLibre understands, as a CSS color.
  static String? cssColor(Object? value) {
    if (value is! String || value.isEmpty) {
      return null;
    }
    final hex = RegExp(r'^#([0-9a-fA-F]{8})$').firstMatch(value)?.group(1);
    if (hex == null) {
      return value;
    }
    final argb = int.parse(hex, radix: 16);
    final a = ((argb >> 24) & 0xFF) / 255;
    return 'rgba(${(argb >> 16) & 0xFF},${(argb >> 8) & 0xFF},${argb & 0xFF},${a.toStringAsFixed(3)})';
  }

  static const pointFilter = [
    '==',
    ['geometry-type'],
    'Point',
  ];
  static const lineFilter = [
    '==',
    ['geometry-type'],
    'LineString',
  ];
  static const polygonFilter = [
    '==',
    ['geometry-type'],
    'Polygon',
  ];
  static const labelFilter = [
    'all',
    [
      '==',
      ['geometry-type'],
      'Point',
    ],
    ['has', 'label'],
  ];

  static String fillLayerId(MapPluginLayer layer) => '${layer.sourceId}.fill';
  static String lineLayerId(MapPluginLayer layer) => '${layer.sourceId}.line';
  static String circleLayerId(MapPluginLayer layer) => '${layer.sourceId}.circle';
  static String labelLayerId(MapPluginLayer layer) => '${layer.sourceId}.label';

  static List<String> styleLayerIds(MapPluginLayer layer) => [
    fillLayerId(layer),
    lineLayerId(layer),
    circleLayerId(layer),
    labelLayerId(layer),
  ];
}
