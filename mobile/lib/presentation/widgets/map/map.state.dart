import 'dart:async';

import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/domain/models/time_range.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/presentation/widgets/map/map_utils.dart';
import 'package:immich_mobile/providers/infrastructure/map.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/map/map_state.provider.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

part 'map.state.freezed.dart';

@Freezed(equal: false)
abstract class MapState with _$MapState {
  const MapState._();

  const factory MapState({
    @Default(ThemeMode.system) ThemeMode themeMode,
    required LatLngBounds bounds,
    @Default(false) bool onlyFavorites,
    @Default(false) bool includeArchived,
    @Default(false) bool withPartners,
    @Default(0) int relativeDays,
    @Default(TimeRange()) TimeRange timeRange,
  }) = _MapState;

  // We only care about bounds changes, overriding Freezed
  @override
  bool operator ==(covariant MapState other) {
    return bounds == other.bounds;
  }

  @override
  int get hashCode => bounds.hashCode;

  TimelineMapOptions toOptions() => TimelineMapOptions(
    bounds: bounds,
    onlyFavorites: onlyFavorites,
    includeArchived: includeArchived,
    withPartners: withPartners,
    relativeDays: relativeDays,
    timeRange: timeRange,
  );
}

/// The map settings as plugins see them (`map.settingsChanged`, `map.state`).
Map<String, dynamic> mapSettingsJson(MapState state) => {
  'themeMode': state.themeMode.name,
  'onlyFavorites': state.onlyFavorites,
  'includeArchived': state.includeArchived,
  'withPartners': state.withPartners,
  'relativeDays': state.relativeDays,
  'timeRange': {
    'from': state.timeRange.from?.toUtc().toIso8601String(),
    'to': state.timeRange.to?.toUtc().toIso8601String(),
  },
};

class MapStateNotifier extends Notifier<MapState> {
  MapStateNotifier();

  void _settingChanged(String key, Object? value) => LibraryPluginHooks.emit(
    LibraryEvents.mapSettingsChanged,
    () => {'key': key, 'value': value, 'settings': mapSettingsJson(state)},
  );

  bool setBounds(LatLngBounds bounds) {
    if (state.bounds == bounds) {
      return false;
    }
    state = state.copyWith(bounds: bounds);
    return true;
  }

  void switchTheme(ThemeMode mode) {
    // TODO: Remove this line when map theme provider is removed
    // Until then, keep both in sync as MapThemeOverride uses map state provider
    // ref.read(appSettingsServiceProvider).setSetting(AppSettingsEnum.mapThemeMode, mode.index);
    ref.read(mapStateNotifierProvider.notifier).switchTheme(mode);
    state = state.copyWith(themeMode: mode);
    _settingChanged('themeMode', mode.name);
  }

  void switchFavoriteOnly(bool isFavoriteOnly) {
    unawaited(ref.read(settingsProvider).write(.mapShowFavoriteOnly, isFavoriteOnly));
    state = state.copyWith(onlyFavorites: isFavoriteOnly);
    EventStream.shared.emit(const MapMarkerReloadEvent());
    _settingChanged('onlyFavorites', isFavoriteOnly);
  }

  void switchIncludeArchived(bool isIncludeArchived) {
    unawaited(ref.read(settingsProvider).write(.mapIncludeArchived, isIncludeArchived));
    state = state.copyWith(includeArchived: isIncludeArchived);
    EventStream.shared.emit(const MapMarkerReloadEvent());
    _settingChanged('includeArchived', isIncludeArchived);
  }

  void switchWithPartners(bool isWithPartners) {
    unawaited(ref.read(settingsProvider).write(.mapWithPartners, isWithPartners));
    state = state.copyWith(withPartners: isWithPartners);
    EventStream.shared.emit(const MapMarkerReloadEvent());
    _settingChanged('withPartners', isWithPartners);
  }

  void setRelativeTime(int relativeDays) {
    unawaited(ref.read(settingsProvider).write(.mapRelativeDate, relativeDays));
    state = state.copyWith(relativeDays: relativeDays);
    EventStream.shared.emit(const MapMarkerReloadEvent());
    _settingChanged('relativeDays', relativeDays);
  }

  void setCustomTimeRange(TimeRange range) {
    unawaited(ref.read(settingsProvider).write(.mapCustomFrom, range.from));
    unawaited(ref.read(settingsProvider).write(.mapCustomTo, range.to));
    state = state.copyWith(timeRange: range);
    EventStream.shared.emit(const MapMarkerReloadEvent());
    _settingChanged('timeRange', {
      'from': range.from?.toUtc().toIso8601String(),
      'to': range.to?.toUtc().toIso8601String(),
    });
  }

  @override
  MapState build() {
    final mapConfig = ref.read(appConfigProvider.select((config) => config.map));
    return MapState(
      themeMode: mapConfig.themeMode,
      onlyFavorites: mapConfig.favoritesOnly,
      includeArchived: mapConfig.includeArchived,
      withPartners: mapConfig.withPartners,
      relativeDays: mapConfig.relativeDays,
      bounds: LatLngBounds(northeast: const LatLng(0, 0), southwest: const LatLng(0, 0)),
      timeRange: TimeRange(from: mapConfig.customFrom, to: mapConfig.customTo),
    );
  }
}

// This provider watches the markers from the map service and serves the markers.
// It should be used only after the map service provider is overridden
final mapMarkerProvider = FutureProvider.family<Map<String, dynamic>, LatLngBounds?>((ref, bounds) async {
  final mapService = ref.watch(mapServiceProvider);
  final hooked = LibraryPluginHooks.query<Marker>(
    LibraryHooks.mapMarkersQuery,
    await mapService.getMarkers(bounds),
    id: (marker) => marker.assetId,
    toJson: (marker) => {
      'id': marker.assetId,
      'assetId': marker.assetId,
      'lat': marker.location.latitude,
      'lng': marker.location.longitude,
    },
    fromJson: (json) {
      final lat = json['lat'];
      final lng = json['lng'];
      final id = json['assetId'] ?? json['id'];
      return lat is num && lng is num && id != null
          ? Marker(location: LatLng(lat.toDouble(), lng.toDouble()), assetId: '$id')
          : null;
    },
    args: () => {if (bounds != null) 'bounds': mapBoundsJson(bounds)},
  );
  final markers = hooked is Future<List<Marker>> ? await hooked : hooked;
  final features = List.filled(markers.length, const <String, dynamic>{});
  for (int i = 0; i < markers.length; i++) {
    final marker = markers[i];
    features[i] = {
      'type': 'Feature',
      'id': marker.assetId,
      'geometry': {
        'type': 'Point',
        'coordinates': [marker.location.longitude, marker.location.latitude],
      },
    };
  }
  return {'type': 'FeatureCollection', 'features': features};
}, dependencies: [mapServiceProvider]);

final mapStateProvider = NotifierProvider<MapStateNotifier, MapState>(MapStateNotifier.new);
