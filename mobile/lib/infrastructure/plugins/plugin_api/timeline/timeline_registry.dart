/// Live timelines, action surfaces and the tab shell, as plugin host functions see them.
///
/// Widgets register a handle while they are mounted; host functions act on the active one. Pure Dart: the
/// interfaces only speak JSON-compatible values and asset ids.
library;

import 'package:collection/collection.dart';

/// How [TimelineHandle.select] changes the selection.
enum SelectionChange { set, add, remove }

/// A timeline that is on screen (or kept alive in a tab).
abstract interface class TimelineHandle {
  /// Page id (`mainTimeline`, `archive`, ...; see `TimelinePages`).
  String get page;

  /// `TimelineOrigin` name of the timeline's query.
  String get origin;

  /// Whether the timeline is visible: its route is the current one and its tab is active.
  bool get isVisible;

  int get totalAssets;

  /// Reloads the timeline, running `timeline.query` again.
  Future<void> refresh();

  /// Scrolls so the asset with [assetId] (id, local id or remote id) is visible. False when it is not in the timeline.
  Future<bool> scrollToAsset(String assetId);

  /// Scrolls to the asset at [index].
  Future<bool> scrollToIndex(int index);

  /// Scrolls to the group of [date] (same day, else same month).
  Future<bool> scrollToDate(DateTime date);

  /// `{ "page", "origin", "firstIndex", "lastIndex", "total", "assetIds" }` of the assets on screen.
  Future<Map<String, dynamic>> visibleRange();

  /// Assets in timeline order (after `timeline.query`), as timeline asset JSON.
  Future<List<Map<String, dynamic>>> assets(int offset, int limit);

  /// `{ "enabled", "count", "assetIds" }` of the current selection.
  Map<String, dynamic> selection();

  /// Changes the selection by asset ids; returns the new selection count.
  Future<int> select(List<String> assetIds, SelectionChange change);

  void clearSelection();

  /// Selects every asset of the timeline; returns the selection count.
  Future<int> selectAll();
}

/// A bar, sheet or menu that lists actions for a set of assets (`selection` for the timeline selection sheet,
/// `viewer` for the viewer's bars).
abstract interface class ActionSurfaceHandle {
  /// `selection` or `viewer`.
  String get surface;

  bool get isVisible;

  /// Applicable actions in display order: `[{ "id", "label", "icon", "builtin" }]`, after plugin rules.
  List<Map<String, dynamic>> listActions();

  /// Runs action [actionId] on [assetIds] (the current selection or asset when null). False when the action does
  /// not apply to those assets.
  Future<bool> runAction(String actionId, List<String>? assetIds);
}

/// The home screen's bottom navigation.
abstract interface class TabShellHandle {
  /// `[{ "id", "title", "builtin", "selected" }]` in display order (hidden built-ins are left out).
  List<Map<String, dynamic>> tabs();

  String? get selectedTab;

  /// Selects tab [id] (`photos`, `albums`, `private` or `plugin:<plugin>/<id>`). False when there is no such tab.
  bool selectTab(String id);
}

abstract final class TimelineRegistry {
  static final List<TimelineHandle> _timelines = [];
  static final List<ActionSurfaceHandle> _surfaces = [];
  static TabShellHandle? _tabShell;

  static void registerTimeline(TimelineHandle handle) {
    _timelines
      ..remove(handle)
      ..add(handle);
  }

  static void unregisterTimeline(TimelineHandle handle) => _timelines.remove(handle);

  /// The visible timeline registered last, else the one registered last.
  static TimelineHandle? get activeTimeline =>
      _timelines.lastWhereOrNull((handle) => handle.isVisible) ?? _timelines.lastOrNull;

  static List<TimelineHandle> get timelines => List.unmodifiable(_timelines);

  static void registerSurface(ActionSurfaceHandle handle) {
    _surfaces
      ..remove(handle)
      ..add(handle);
  }

  static void unregisterSurface(ActionSurfaceHandle handle) => _surfaces.remove(handle);

  /// The visible surface named [surface] (any surface when null) registered last.
  static ActionSurfaceHandle? activeSurface([String? surface]) {
    final matching = _surfaces.where((handle) => surface == null || handle.surface == surface);
    return matching.lastWhereOrNull((handle) => handle.isVisible) ?? matching.lastOrNull;
  }

  static void registerTabShell(TabShellHandle handle) => _tabShell = handle;

  static void unregisterTabShell(TabShellHandle handle) {
    if (identical(_tabShell, handle)) {
      _tabShell = null;
    }
  }

  static TabShellHandle? get tabShell => _tabShell;
}
