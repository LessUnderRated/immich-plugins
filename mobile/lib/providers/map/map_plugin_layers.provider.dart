import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/map_plugin_layers.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Runs the tap action of a plugin map feature: `{ "method", "params"? }` or `{ "command": {...} }`, with
/// [data] = `{ "layer", "feature", "lat", "lng", "data" }`.
typedef MapPluginActionHandler =
    Future<void> Function(String plugin, Map<String, dynamic> action, Map<String, dynamic> data);

/// Layers plugins draw on the map, by `<plugin>/<layer id>`. Kept for the app session so a plugin can prepare
/// layers before the map opens.
class MapPluginLayersNotifier extends Notifier<Map<String, MapPluginLayer>> {
  @override
  Map<String, MapPluginLayer> build() => const {};

  /// Adds or replaces [layer].
  void put(MapPluginLayer layer) => state = {...state, layer.key: layer};

  /// Removes layer [id] of [plugin]; returns whether it existed.
  bool remove(String plugin, String id) {
    final key = '$plugin/$id';
    if (!state.containsKey(key)) {
      return false;
    }
    state = {...state}..remove(key);
    return true;
  }

  /// Removes every layer of [plugin] (or of every plugin when null); returns how many were removed.
  int clear([String? plugin]) {
    final kept = {
      for (final entry in state.entries)
        if (plugin != null && entry.value.plugin != plugin) entry.key: entry.value,
    };
    final removed = state.length - kept.length;
    if (removed > 0) {
      state = kept;
    }
    return removed;
  }

  /// Shows or hides layer [id] of [plugin]; returns whether it exists.
  bool setVisible(String plugin, String id, bool visible) {
    final layer = state['$plugin/$id'];
    if (layer == null) {
      return false;
    }
    put(
      MapPluginLayer(
        plugin: layer.plugin,
        id: layer.id,
        features: layer.features,
        visible: visible,
        minZoom: layer.minZoom,
        maxZoom: layer.maxZoom,
        action: layer.action,
      ),
    );
    return true;
  }

  List<MapPluginLayer> of(String plugin) => [
    for (final layer in state.values)
      if (layer.plugin == plugin) layer,
  ];
}

final mapPluginLayersProvider = NotifierProvider<MapPluginLayersNotifier, Map<String, MapPluginLayer>>(
  MapPluginLayersNotifier.new,
);

/// Where taps on plugin map features go. The plugin kernel installs [handler] when it starts; without one, taps
/// only emit the `map.featureTapped` event.
class MapPluginActions {
  MapPluginActionHandler? handler;
}

final mapPluginActionsProvider = Provider<MapPluginActions>((ref) => MapPluginActions());

/// The map page currently on screen, for the `map.camera.*` host functions. [controller] is null while no map page
/// is open.
class MapViewHandle {
  MapLibreMapController? controller;
}

final mapViewHandleProvider = Provider<MapViewHandle>((ref) => MapViewHandle());
