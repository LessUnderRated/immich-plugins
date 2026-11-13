import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/asyncvalue_extensions.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/map_plugin_layers.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/base_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/map_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/library/library_plugins.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart';
import 'package:immich_mobile/presentation/widgets/map/map_utils.dart';
import 'package:immich_mobile/providers/map/map_plugin_layers.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/utils/async_mutex.dart';
import 'package:immich_mobile/utils/debounce.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_mobile/widgets/map/map_theme_override.dart';
import 'package:logging/logging.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:url_launcher/url_launcher.dart';

class CustomSourceProperties implements SourceProperties {
  final Map<String, dynamic> data;
  const CustomSourceProperties({required this.data});

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "geojson",
      "data": data,
      // "cluster": true,
      // "clusterRadius": 1,
      // "clusterMinPoints": 5,
      // "tolerance": 0.1,
    };
  }
}

class MapView extends ConsumerStatefulWidget {
  final LatLng? initialLocation;

  const MapView({super.key, this.initialLocation});

  @override
  ConsumerState<MapView> createState() => _MapViewState();
}

class _MapViewState extends ConsumerState<MapView> {
  static final _log = Logger('MapView');

  MapLibreMapController? mapController;
  final _reloadMutex = AsyncMutex();
  final _pluginLayerMutex = AsyncMutex();

  /// Plugin layers currently added to the map style, by `<plugin>/<id>`.
  final Map<String, MapPluginLayer> _shownPluginLayers = {};
  bool _styleReady = false;
  late final MapViewHandle _viewHandle;
  final _debouncer = Debouncer(interval: const Duration(milliseconds: 500), maxWaitTime: const Duration(seconds: 2));
  final ValueNotifier<double> bottomSheetOffset = ValueNotifier(0.25);
  final GlobalKey _bottomSheetKey = GlobalKey();
  StreamSubscription? _eventSubscription;
  MapAttribution? _attribution;

  @override
  void initState() {
    super.initState();
    _eventSubscription = EventStream.shared.listen<MapMarkerReloadEvent>(_onEvent);
    _viewHandle = ref.read(mapViewHandleProvider);
    final initialLocation = widget.initialLocation;
    LibraryPluginHooks.emit(
      LibraryEvents.mapOpened,
      () => {
        'initialLocation': initialLocation == null
            ? null
            : {'lat': initialLocation.latitude, 'lng': initialLocation.longitude},
      },
    );
  }

  @override
  void dispose() {
    final controller = mapController;
    if (controller != null) {
      controller.onFeatureTapped.remove(_onFeatureTapped);
      if (identical(_viewHandle.controller, controller)) {
        _viewHandle.controller = null;
      }
    }
    _debouncer.dispose();
    bottomSheetOffset.dispose();
    unawaited(_eventSubscription?.cancel());
    super.dispose();
  }

  void onMapCreated(MapLibreMapController controller) {
    mapController = controller;
    _viewHandle.controller = controller;
  }

  void _onEvent(_) => _debouncer.run(() => setBounds(forceReload: true));

  Future<void> onMapReady() async {
    final controller = mapController;
    if (controller == null) {
      return;
    }

    // Start the fetch as soon as possible
    final attributionLoaded = MapUtils.getAttribution(controller);

    await controller.addSource(
      MapUtils.defaultSourceId,
      const CustomSourceProperties(data: {'type': 'FeatureCollection', 'features': []}),
    );

    if (Platform.isAndroid) {
      await controller.addCircleLayer(
        MapUtils.defaultSourceId,
        MapUtils.defaultHeatMapLayerId,
        const CircleLayerProperties(
          circleRadius: 10,
          circleColor: "rgba(150,86,34,0.7)",
          circleBlur: 1.0,
          circleOpacity: 0.7,
          circleStrokeWidth: 0.1,
          circleStrokeColor: "rgba(203,46,19,0.5)",
          circleStrokeOpacity: 0.7,
        ),
      );
    }

    if (Platform.isIOS) {
      await controller.addHeatmapLayer(
        MapUtils.defaultSourceId,
        MapUtils.defaultHeatMapLayerId,
        MapUtils.defaultHeatmapLayerProperties,
      );
    }

    _debouncer.run(() => setBounds(forceReload: true));
    controller.addListener(onMapMoved);
    controller.onFeatureTapped.add(_onFeatureTapped);
    _styleReady = true;
    unawaited(_syncPluginLayers());

    final attribution = await attributionLoaded;
    if (mounted) {
      setState(() => _attribution = attribution);
    }
  }

  void onMapMoved() {
    if (mapController!.isCameraMoving || !mounted) {
      return;
    }

    _debouncer.run(setBounds);
  }

  Future<void> setBounds({bool forceReload = false}) async {
    final controller = mapController;
    if (controller == null || !mounted) {
      return;
    }

    // When the AssetViewer is open, the DriftMap route stays alive in the background.
    // If we continue to update bounds, the map-scoped timeline service gets recreated and the previous one disposed,
    // which can invalidate the TimelineService instance that was passed into AssetViewerRoute (causing "loading forever").
    if (ref.read(isAssetViewerOpenProvider)) {
      return;
    }

    final bounds = await controller.getVisibleRegion();
    unawaited(
      _reloadMutex.run(() async {
        if (mounted && (ref.read(mapStateProvider.notifier).setBounds(bounds) || forceReload)) {
          final markers = await ref.read(mapMarkerProvider(bounds).future);
          await reloadMarkers(markers);
          LibraryPluginHooks.emit(
            LibraryEvents.mapMoved,
            () => {'bounds': mapBoundsJson(bounds), 'zoom': controller.cameraPosition?.zoom},
          );
        }
      }),
    );
  }

  /// Brings the plugin layers on the map in line with [mapPluginLayersProvider].
  Future<void> _syncPluginLayers() => _pluginLayerMutex.run(() async {
    final controller = mapController;
    if (controller == null || !_styleReady || !mounted) {
      return;
    }
    final wanted = ref.read(mapPluginLayersProvider);
    for (final key in _shownPluginLayers.keys.toList()) {
      if (!wanted.containsKey(key)) {
        await _removePluginLayer(controller, _shownPluginLayers.remove(key)!);
      }
    }
    for (final layer in wanted.values) {
      final shown = _shownPluginLayers[layer.key];
      if (identical(shown, layer)) {
        continue;
      }
      try {
        if (shown == null || shown.minZoom != layer.minZoom || shown.maxZoom != layer.maxZoom) {
          if (shown != null) {
            await _removePluginLayer(controller, shown);
          }
          await _addPluginLayer(controller, layer);
        } else {
          await controller.setGeoJsonSource(layer.sourceId, MapPluginGeoJson.source(layer));
        }
        if ((shown?.visible ?? true) != layer.visible) {
          for (final id in MapPluginGeoJson.styleLayerIds(layer)) {
            await controller.setLayerVisibility(id, layer.visible);
          }
        }
        _shownPluginLayers[layer.key] = layer;
      } catch (error, stack) {
        _log.warning('Cannot show map layer ${layer.key}', error, stack);
      }
    }
  });

  Future<void> _addPluginLayer(MapLibreMapController controller, MapPluginLayer layer) async {
    final source = layer.sourceId;
    await controller.addGeoJsonSource(source, MapPluginGeoJson.source(layer));
    await controller.addFillLayer(
      source,
      MapPluginGeoJson.fillLayerId(layer),
      const FillLayerProperties(
        fillColor: ['get', 'color'],
        fillOpacity: ['get', 'opacity'],
        fillOutlineColor: ['get', 'outlineColor'],
      ),
      filter: MapPluginGeoJson.polygonFilter,
      minzoom: layer.minZoom,
      maxzoom: layer.maxZoom,
    );
    await controller.addLineLayer(
      source,
      MapPluginGeoJson.lineLayerId(layer),
      const LineLayerProperties(
        lineColor: ['get', 'color'],
        lineWidth: ['get', 'width'],
        lineOpacity: ['get', 'opacity'],
        lineJoin: 'round',
        lineCap: 'round',
      ),
      filter: MapPluginGeoJson.lineFilter,
      minzoom: layer.minZoom,
      maxzoom: layer.maxZoom,
    );
    await controller.addCircleLayer(
      source,
      MapPluginGeoJson.circleLayerId(layer),
      const CircleLayerProperties(
        circleColor: ['get', 'color'],
        circleRadius: ['get', 'radius'],
        circleOpacity: ['get', 'opacity'],
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2,
      ),
      filter: MapPluginGeoJson.pointFilter,
      minzoom: layer.minZoom,
      maxzoom: layer.maxZoom,
    );
    try {
      // Labels need glyphs in the map style; a style without them still shows the shapes
      await controller.addSymbolLayer(
        source,
        MapPluginGeoJson.labelLayerId(layer),
        const SymbolLayerProperties(
          textField: ['get', 'label'],
          textSize: 12,
          textOffset: [0, 1.6],
          textColor: ['get', 'labelColor'],
          textHaloColor: '#FFFFFF',
          textHaloWidth: 1,
          textAllowOverlap: true,
        ),
        filter: MapPluginGeoJson.labelFilter,
        minzoom: layer.minZoom,
        maxzoom: layer.maxZoom,
        enableInteraction: false,
      );
    } catch (error) {
      _log.fine('No labels for map layer ${layer.key}: $error');
    }
    if (!layer.visible) {
      for (final id in MapPluginGeoJson.styleLayerIds(layer)) {
        await controller.setLayerVisibility(id, false);
      }
    }
  }

  Future<void> _removePluginLayer(MapLibreMapController controller, MapPluginLayer layer) async {
    for (final id in MapPluginGeoJson.styleLayerIds(layer)) {
      try {
        await controller.removeLayer(id);
      } catch (_) {
        // The label layer may not exist
      }
    }
    try {
      await controller.removeSource(layer.sourceId);
    } catch (error, stack) {
      _log.warning('Cannot remove map layer ${layer.key}', error, stack);
    }
  }

  void _onFeatureTapped(Point<double> point, LatLng coordinates, String id, String layerId, Annotation? annotation) {
    if (layerId == MapUtils.defaultHeatMapLayerId) {
      LibraryPluginHooks.emit(
        LibraryEvents.mapMarkerTapped,
        () => {'assetId': id, 'lat': coordinates.latitude, 'lng': coordinates.longitude},
      );
      return;
    }
    final layer = _shownPluginLayers.values.firstWhereOrNull((layer) => layerId.startsWith('${layer.sourceId}.'));
    final feature = layer?.feature(id);
    if (layer == null || feature == null) {
      return;
    }
    final data = <String, dynamic>{
      'plugin': layer.plugin,
      'layer': layer.id,
      'featureId': feature.id,
      'feature': feature.toJson(),
      'lat': coordinates.latitude,
      'lng': coordinates.longitude,
      'data': feature.data,
    };
    LibraryPluginHooks.emit(LibraryEvents.mapFeatureTapped, () => data);
    final action = feature.action ?? layer.action;
    final handler = ref.read(mapPluginActionsProvider).handler;
    if (action == null || handler == null) {
      return;
    }
    unawaited(
      runLibraryFlow<void>(
        context,
        LibraryHooks.mapFeatureTap,
        () => handler(layer.plugin, action, data),
        args: () => {...data, 'action': action},
      ),
    );
  }

  Future<void> reloadMarkers(Map<String, dynamic> markers) async {
    final controller = mapController;
    if (controller == null || !mounted) {
      return;
    }

    await controller.setGeoJsonSource(MapUtils.defaultSourceId, markers);
  }

  Future<void> onZoomToLocation() async {
    final (location, error) = await MapUtils.checkPermAndGetLocation(context: context);
    if (error != null) {
      if (error == LocationPermission.unableToDetermine && context.mounted) {
        ImmichToast.show(
          context: context,
          gravity: ToastGravity.BOTTOM,
          toastType: ToastType.error,
          msg: context.t.map_cannot_get_user_location,
        );
      }
      return;
    }

    final controller = mapController;
    if (controller != null && location != null) {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(location.latitude, location.longitude), MapUtils.mapZoomToAssetLevel),
        duration: const Duration(milliseconds: 800),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(isAssetViewerOpenProvider, (previous, current) {
      if (previous == true && !current) {
        _debouncer.run(() => setBounds(forceReload: true));
      }
    });
    ref.listen(mapPluginLayersProvider, (_, _) => unawaited(_syncPluginLayers()));
    return Stack(
      children: [
        _Map(initialLocation: widget.initialLocation, onMapCreated: onMapCreated, onMapReady: onMapReady),
        _DynamicBottomSheet(bottomSheetOffset: bottomSheetOffset, sheetKey: _bottomSheetKey),
        _DynamicBottomButtons(
          onZoomToLocation: () => libraryTap(context, LibraryPages.map, 'myLocation', onZoomToLocation),
          bottomSheetOffset: bottomSheetOffset,
          attribution: _attribution,
        ),
      ],
    );
  }
}

class _Map extends StatelessWidget {
  final LatLng? initialLocation;

  const _Map({this.initialLocation, required this.onMapCreated, required this.onMapReady});

  final MapCreatedCallback onMapCreated;

  final VoidCallback onMapReady;

  @override
  Widget build(BuildContext context) {
    final initialLocation = this.initialLocation;
    return MapThemeOverride(
      mapBuilder: (style) => style.widgetWhen(
        onData: (style) => MapLibreMap(
          initialCameraPosition: initialLocation == null
              ? const CameraPosition(target: LatLng(0, 0), zoom: 0)
              : CameraPosition(target: initialLocation, zoom: MapUtils.mapZoomToAssetLevel),
          compassEnabled: false,
          rotateGesturesEnabled: false,
          styleString: style,
          onMapCreated: onMapCreated,
          onStyleLoadedCallback: onMapReady,
          // Hide offscreen so we can draw our own
          attributionButtonMargins: const Point(-200, 0),
        ),
      ),
    );
  }
}

class _DynamicBottomSheet extends StatefulWidget {
  final ValueNotifier<double> bottomSheetOffset;
  final GlobalKey sheetKey;

  const _DynamicBottomSheet({required this.bottomSheetOffset, required this.sheetKey});

  @override
  State<_DynamicBottomSheet> createState() => _DynamicBottomSheetState();
}

class _DynamicBottomSheetState extends State<_DynamicBottomSheet> {
  @override
  Widget build(BuildContext context) {
    return NotificationListener<DraggableScrollableNotification>(
      onNotification: (notification) {
        final sheet = notification.context.findAncestorWidgetOfExactType<BaseBottomSheet>();
        if (sheet?.key == widget.sheetKey) {
          widget.bottomSheetOffset.value = notification.extent;
        }
        return false;
      },
      child: MapBottomSheet(sheetKey: widget.sheetKey),
    );
  }
}

class _DynamicBottomButtons extends StatelessWidget {
  const _DynamicBottomButtons({
    required this.onZoomToLocation,
    required this.bottomSheetOffset,
    required this.attribution,
  });

  final VoidCallback onZoomToLocation;
  final ValueNotifier<double> bottomSheetOffset;
  final MapAttribution? attribution;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: bottomSheetOffset,
      builder: (context, offset, child) {
        return Positioned(
          left: 20,
          right: 20,
          bottom: context.height * (offset - 0.02) + context.padding.bottom,
          child: AnimatedOpacity(
            opacity: offset < 0.8 ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: Row(
              children: [
                // The map data's attribution must stay visible, so it is not a hideable item
                if (attribution case final attribution?) _AttributionButton(attribution: attribution),
                const Spacer(),
                ...LibraryPluginHooks.arrange(LibrarySlots.mapControls, [
                  (
                    id: 'myLocation',
                    item: ElevatedButton(
                      onPressed: onZoomToLocation,
                      style: ElevatedButton.styleFrom(shape: const CircleBorder()),
                      child: const Icon(Icons.my_location),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AttributionButton extends StatefulWidget {
  const _AttributionButton({required this.attribution});

  final MapAttribution attribution;

  @override
  State<_AttributionButton> createState() => _AttributionButtonState();
}

class _AttributionButtonState extends State<_AttributionButton> {
  // OSM's attribution guidelines require it to be visible by default
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final (:text, :url) = widget.attribution;
    return TapRegion(
      // Any interaction outside of the popup causes it to close
      onTapOutside: _expanded ? (_) => setState(() => _expanded = false) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ElevatedButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            style: ElevatedButton.styleFrom(shape: const CircleBorder()),
            child: const Icon(Icons.info_outline),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 100),
            child: _expanded
                ? Material(
                    // Without a key the transition remotes pill instantly instead of fading it out
                    key: const ValueKey('attribution'),
                    color: context.colorScheme.surfaceContainerLow,
                    elevation: 1,
                    shape: const StadiumBorder(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: context.width / 2),
                      child: TextButton(
                        onPressed: url == null
                            ? null
                            : () => unawaited(launchUrl(url, mode: LaunchMode.externalApplication)),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 40),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          disabledForegroundColor: context.colorScheme.onSurface,
                        ),
                        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
