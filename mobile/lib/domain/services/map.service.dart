import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/infrastructure/repositories/map.repository.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

typedef MapMarkerSource = Future<List<Marker>> Function(LatLngBounds? bounds);

typedef MapQuery = ({MapMarkerSource markerSource});

class MapFactory {
  final MapRepository _mapRepository;

  const MapFactory({required this._mapRepository});

  MapService remote(List<String> ownerIds, TimelineMapOptions options) =>
      MapService(_mapRepository.remote(ownerIds, options));
}

class MapService {
  final MapMarkerSource _markerSource;

  MapService(MapQuery query) : _markerSource = query.markerSource;

  /// Map markers; plugins can filter or extend them through `map.query` (the bounds are in the arguments).
  Future<List<Marker>> Function(LatLngBounds? bounds) get getMarkers => _filtered;

  Future<List<Marker>> _filtered(LatLngBounds? bounds) async => PluginHooks.filterList<Marker>(
    DataHooks.mapQuery,
    () => {
      if (bounds != null) ...{
        'north': bounds.northeast.latitude,
        'east': bounds.northeast.longitude,
        'south': bounds.southwest.latitude,
        'west': bounds.southwest.longitude,
      },
    },
    await _markerSource(bounds),
    () => PluginListCodec<Marker>(
      id: (marker) => marker.assetId,
      toJson: PluginJson.marker,
      fromJson: (json) {
        final latitude = PluginArgs.real(json['latitude']);
        final longitude = PluginArgs.real(json['longitude']);
        final assetId = PluginArgs.string(json['assetId'] ?? json['id']);
        return latitude == null || longitude == null || assetId == null
            ? null
            : Marker(location: LatLng(latitude, longitude), assetId: assetId);
      },
    ),
  );
}
