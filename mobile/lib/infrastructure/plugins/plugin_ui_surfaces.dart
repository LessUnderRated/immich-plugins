import 'package:flutter/foundation.dart';

/// One mounted JSON UI surface (a page, settings page, slot section, dialog, sheet or overlay).
///
/// Plugins target surfaces by id with `ui.update(surfaceId, tree)`, `ui.patch(surfaceId, nodeId, props)` and
/// `ui.setState(surfaceId, state)`. Every surface tells its plugin its id (`surface` in `PageV1`, `SlotV1` and
/// `UiEventV1` data); plugins may also choose ids (`"surface"` in commands and slot items).
class PluginUiSurface extends ChangeNotifier {
  final String plugin;
  final String id;
  Map<String, dynamic>? _tree;
  Map<String, dynamic> _pushedState = const {};
  var _revision = 0;

  PluginUiSurface._(this.plugin, this.id);

  Map<String, dynamic>? get tree => _tree;

  /// Increments on every change; renderers compare it to know what changed.
  int get revision => _revision;

  /// Input values pushed by the plugin since the renderer last read them (see [takeState]).
  bool get hasPushedState => _pushedState.isNotEmpty;

  /// Replaces the tree (and optionally input values) and notifies the renderer.
  void setTree(Map<String, dynamic>? tree, {Map<String, dynamic>? state, bool notify = true}) {
    _tree = tree == null ? null : _copy(tree) as Map<String, dynamic>;
    if (state != null && state.isNotEmpty) {
      _pushedState = {..._pushedState, ...state};
    }
    _revision++;
    if (notify) {
      notifyListeners();
    }
  }

  /// Merges [props] into the node whose `id` is [nodeId] (a null value removes the prop). Returns whether it was found.
  bool patch(String nodeId, Map<String, dynamic> props) {
    final tree = _tree;
    final node = tree == null ? null : _find(tree, nodeId);
    if (node == null) {
      return false;
    }
    for (final MapEntry(:key, :value) in props.entries) {
      value == null ? node.remove(key) : node[key] = _copy(value);
    }
    if (props.containsKey('value') && node['id'] is String) {
      _pushedState = {..._pushedState, node['id'] as String: props['value']};
    }
    _revision++;
    notifyListeners();
    return true;
  }

  /// Sets input values without changing the tree.
  void pushState(Map<String, dynamic> state) {
    if (state.isEmpty) {
      return;
    }
    _pushedState = {..._pushedState, ...state};
    _revision++;
    notifyListeners();
  }

  /// Returns and clears the input values pushed by the plugin.
  Map<String, dynamic> takeState() {
    final state = _pushedState;
    _pushedState = const {};
    return state;
  }

  static Map<String, dynamic>? _find(Object? node, String id) {
    if (node is Map) {
      if (node['id'] == id && node is Map<String, dynamic>) {
        return node;
      }
      for (final value in node.values) {
        final found = _find(value, id);
        if (found != null) {
          return found;
        }
      }
    } else if (node is List) {
      for (final item in node) {
        final found = _find(item, id);
        if (found != null) {
          return found;
        }
      }
    }
    return null;
  }

  /// Deep copy into mutable `Map<String, dynamic>` / `List<dynamic>`.
  static Object? _copy(Object? value) {
    if (value is Map) {
      return <String, dynamic>{for (final MapEntry(:key, :value) in value.entries) '$key': _copy(value)};
    }
    if (value is List) {
      return [for (final item in value) _copy(item)];
    }
    return value;
  }

  Map<String, dynamic> describe() => {'plugin': plugin, 'surface': id, 'hasTree': _tree != null};
}

/// Registry of mounted surfaces, keyed by plugin and surface id. Several mounted instances may share an id (the same
/// section on two pages); updates reach all of them. An update for a surface that is not mounted yet is kept for a
/// few seconds and applied when it mounts.
class PluginUiSurfaces {
  static const _pendingFor = Duration(seconds: 10);

  final Map<String, Set<PluginUiSurface>> _surfaces = {};
  final Map<String, (DateTime, Map<String, dynamic>?, Map<String, dynamic>?)> _pending = {};

  static String _key(String plugin, String id) => '$plugin\n$id';

  PluginUiSurface attach(String plugin, String id) {
    final surface = PluginUiSurface._(plugin, id);
    _surfaces.putIfAbsent(_key(plugin, id), () => {}).add(surface);
    final pending = _pending.remove(_key(plugin, id));
    if (pending != null && DateTime.now().difference(pending.$1) < _pendingFor) {
      surface.setTree(pending.$2, state: pending.$3, notify: false);
    }
    return surface;
  }

  void detach(PluginUiSurface surface) {
    final key = _key(surface.plugin, surface.id);
    final set = _surfaces[key];
    set?.remove(surface);
    if (set != null && set.isEmpty) {
      _surfaces.remove(key);
    }
  }

  Iterable<PluginUiSurface> _of(String plugin, String id) => _surfaces[_key(plugin, id)] ?? const {};

  bool isMounted(String plugin, String id) => _of(plugin, id).isNotEmpty;

  /// Replaces the tree of every mounted instance; returns how many were updated (0 = kept as pending).
  int update(String plugin, String id, Map<String, dynamic>? tree, {Map<String, dynamic>? state}) {
    final surfaces = _of(plugin, id).toList();
    if (surfaces.isEmpty) {
      _pending[_key(plugin, id)] = (DateTime.now(), tree, state);
      return 0;
    }
    for (final surface in surfaces) {
      tree == null ? surface.pushState(state ?? const {}) : surface.setTree(tree, state: state);
    }
    return surfaces.length;
  }

  /// Patches node [nodeId] in every mounted instance; returns how many contained it.
  int patch(String plugin, String id, String nodeId, Map<String, dynamic> props) {
    var count = 0;
    for (final surface in _of(plugin, id).toList()) {
      if (surface.patch(nodeId, props)) {
        count++;
      }
    }
    if (count == 0) {
      final pending = _pending[_key(plugin, id)];
      final tree = pending?.$2;
      if (pending != null && tree != null) {
        final probe = PluginUiSurface._(plugin, id)..setTree(tree, notify: false);
        if (probe.patch(nodeId, props)) {
          _pending[_key(plugin, id)] = (pending.$1, probe.tree, pending.$3);
        }
      }
    }
    return count;
  }

  /// Sets input values in every mounted instance.
  int setState(String plugin, String id, Map<String, dynamic> state) => update(plugin, id, null, state: state);

  List<Map<String, dynamic>> describe({String? plugin}) => [
    for (final set in _surfaces.values)
      for (final surface in set)
        if (plugin == null || surface.plugin == plugin) surface.describe(),
  ];
}

/// Mounted plugin native views (`PluginView`), so plugins can report their content height for inline views.
///
/// Every view gets an `instance` id in its params; the plugin answers with `ui.setContentHeight` /
/// `views.setHeight([instance, heightDp])` or the `setContentHeight` command.
class PluginViewInstances {
  final Map<String, ValueNotifier<double?>> _heights = {};
  var _counter = 0;

  String newInstanceId(String plugin) => '$plugin-view-${DateTime.now().microsecondsSinceEpoch}-${_counter++}';

  ValueNotifier<double?> height(String instance) => _heights.putIfAbsent(instance, () => ValueNotifier(null));

  void release(String instance) => _heights.remove(instance)?.dispose();

  bool setHeight(String instance, double? height) {
    final notifier = _heights[instance];
    if (notifier == null) {
      return false;
    }
    notifier.value = height == null || height <= 0 ? null : height;
    return true;
  }

  List<String> get instances => _heights.keys.toList();
}
