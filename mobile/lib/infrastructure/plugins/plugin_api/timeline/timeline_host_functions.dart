/// Host functions of the timeline area, as plain Dart: `timeline.*`, `selection.*`, `actions.*`, `tabs.*`.
///
/// Each takes the JSON argument array of `host.callHost(name, argsJson)` and returns a JSON-compatible value. They
/// act on the handles in [TimelineRegistry]; the kernel registers them with `registerHost(name, handler)`.
library;

import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_registry.dart';

/// Same shape as the kernel's `HostFunction`.
typedef TimelineHostFunction = Future<Object?> Function(String plugin, List<dynamic> args);

/// Thrown when a host function cannot act (no timeline open, bad arguments); the kernel reports it as a failed call.
class TimelineHostError implements Exception {
  final String message;

  const TimelineHostError(this.message);

  @override
  String toString() => message;
}

abstract final class TimelineHostFunctions {
  /// Every host function of the area by name.
  static Map<String, TimelineHostFunction> get all => {
    TimelineHostNames.refresh: (_, args) => refresh(args),
    TimelineHostNames.scrollTo: (_, args) => scrollTo(args),
    TimelineHostNames.visibleRange: (_, args) => visibleRange(args),
    TimelineHostNames.current: (_, args) => current(args),
    TimelineHostNames.assets: (_, args) => assets(args),
    TimelineHostNames.selectionGet: (_, args) => selectionGet(args),
    TimelineHostNames.selectionSet: (_, args) => selectionChange(args, SelectionChange.set),
    TimelineHostNames.selectionAdd: (_, args) => selectionChange(args, SelectionChange.add),
    TimelineHostNames.selectionRemove: (_, args) => selectionChange(args, SelectionChange.remove),
    TimelineHostNames.selectionClear: (_, args) => selectionClear(args),
    TimelineHostNames.selectionAll: (_, args) => selectionAll(args),
    TimelineHostNames.actionsList: (_, args) => actionsList(args),
    TimelineHostNames.actionsRun: (_, args) => actionsRun(args),
    TimelineHostNames.tabsList: (_, args) => tabsList(args),
    TimelineHostNames.tabsSelect: (_, args) => tabsSelect(args),
  };

  /// One line per function, for `kernel.registerHost(..., doc:)` and introspection.
  static const docs = <String, String>{
    TimelineHostNames.refresh: '[] -> bool. Reloads the active timeline (runs timeline.query again).',
    TimelineHostNames.scrollTo:
        '[assetId] or [{ "assetId"?, "index"?, "date"? }] -> bool. Scrolls the active timeline to an asset, index or date.',
    TimelineHostNames.visibleRange:
        '[] -> { page, origin, firstIndex, lastIndex, total, assetIds } | null. Assets on screen.',
    TimelineHostNames.current: '[] -> { page, origin, total, visible } | null. The active timeline.',
    TimelineHostNames.assets: '[{ "offset"?, "limit"? }] -> [asset]. Assets of the active timeline in display order.',
    TimelineHostNames.selectionGet: '[] -> { enabled, count, assetIds }.',
    TimelineHostNames.selectionSet: '[[assetId]] -> count. Replaces the selection.',
    TimelineHostNames.selectionAdd: '[[assetId]] -> count. Adds to the selection.',
    TimelineHostNames.selectionRemove: '[[assetId]] -> count. Removes from the selection.',
    TimelineHostNames.selectionClear: '[] -> true. Ends selection mode.',
    TimelineHostNames.selectionAll: '[] -> count. Selects every asset of the active timeline.',
    TimelineHostNames.actionsList:
        '[{ "surface"?: "selection"|"viewer" }] -> [{ id, label, icon, builtin }]. Actions that apply now.',
    TimelineHostNames.actionsRun:
        '[actionId, [assetId]?, { "surface"? }?] -> bool. Runs an action (built-in or plugin) on assets.',
    TimelineHostNames.tabsList: '[] -> [{ id, title, builtin, selected }]. Bottom navigation tabs.',
    TimelineHostNames.tabsSelect: '[tabId] -> bool. Selects a bottom navigation tab.',
  };

  static TimelineHandle _timeline() =>
      TimelineRegistry.activeTimeline ?? (throw const TimelineHostError('No timeline is open'));

  static Map<String, dynamic> _options(List<dynamic> args, [int index = 0]) =>
      args.length > index && args[index] is Map ? Map<String, dynamic>.from(args[index] as Map) : const {};

  /// Asset ids from `[[ids]]`, `[ids...]` or `[{ "assetIds": [...] }]`.
  static List<String> _ids(List<dynamic> args) {
    if (args.isEmpty) {
      return const [];
    }
    final first = args.first;
    if (first is List) {
      return PluginArgs.strings(first);
    }
    if (first is Map) {
      return PluginArgs.strings(first['assetIds']);
    }
    return PluginArgs.strings(args);
  }

  static Future<bool> refresh(List<dynamic> args) async {
    final handle = TimelineRegistry.activeTimeline;
    if (handle == null) {
      return false;
    }
    await handle.refresh();
    return true;
  }

  static Future<bool> scrollTo(List<dynamic> args) async {
    final handle = _timeline();
    final first = args.isEmpty ? null : args.first;
    if (first is String) {
      return handle.scrollToAsset(first);
    }
    final options = _options(args);
    final assetId = PluginArgs.string(options['assetId']);
    if (assetId != null) {
      return handle.scrollToAsset(assetId);
    }
    final index = PluginArgs.integer(options['index']);
    if (index != null) {
      return handle.scrollToIndex(index);
    }
    final date = PluginArgs.date(options['date']);
    if (date != null) {
      return handle.scrollToDate(date.toLocal());
    }
    throw const TimelineHostError('scrollTo needs an asset id, an index or a date');
  }

  static Future<Map<String, dynamic>?> visibleRange(List<dynamic> args) async =>
      TimelineRegistry.activeTimeline?.visibleRange();

  static Future<Map<String, dynamic>?> current(List<dynamic> args) async {
    final handle = TimelineRegistry.activeTimeline;
    if (handle == null) {
      return null;
    }
    return {'page': handle.page, 'origin': handle.origin, 'total': handle.totalAssets, 'visible': handle.isVisible};
  }

  static Future<List<Map<String, dynamic>>> assets(List<dynamic> args) {
    final options = _options(args);
    final offset = PluginArgs.integer(options['offset']) ?? 0;
    final limit = PluginArgs.integer(options['limit']) ?? 100;
    if (offset < 0 || limit <= 0) {
      throw const TimelineHostError('offset must be >= 0 and limit > 0');
    }
    return _timeline().assets(offset, limit);
  }

  static Future<Map<String, dynamic>> selectionGet(List<dynamic> args) async =>
      TimelineRegistry.activeTimeline?.selection() ?? const {'enabled': false, 'count': 0, 'assetIds': <String>[]};

  static Future<int> selectionChange(List<dynamic> args, SelectionChange change) =>
      _timeline().select(_ids(args), change);

  static Future<bool> selectionClear(List<dynamic> args) async {
    TimelineRegistry.activeTimeline?.clearSelection();
    return true;
  }

  static Future<int> selectionAll(List<dynamic> args) => _timeline().selectAll();

  static Future<List<Map<String, dynamic>>> actionsList(List<dynamic> args) async {
    final surface = PluginArgs.string(_options(args)['surface']);
    return TimelineRegistry.activeSurface(surface)?.listActions() ?? const [];
  }

  static Future<bool> actionsRun(List<dynamic> args) {
    final String? actionId;
    final List<String>? assetIds;
    final Map<String, dynamic> options;
    if (args.isNotEmpty && args.first is Map) {
      options = _options(args);
      actionId = PluginArgs.string(options['id'] ?? options['actionId']);
      assetIds = options['assetIds'] is List ? PluginArgs.strings(options['assetIds']) : null;
    } else {
      actionId = args.isEmpty ? null : PluginArgs.string(args.first);
      assetIds = args.length > 1 && args[1] is List ? PluginArgs.strings(args[1]) : null;
      options = _options(args, 2);
    }
    if (actionId == null) {
      throw const TimelineHostError('actions.run needs an action id');
    }
    final surface = TimelineRegistry.activeSurface(PluginArgs.string(options['surface']));
    if (surface == null) {
      throw const TimelineHostError('No action bar is open');
    }
    return surface.runAction(actionId, assetIds);
  }

  static Future<List<Map<String, dynamic>>> tabsList(List<dynamic> args) async =>
      TimelineRegistry.tabShell?.tabs() ?? const [];

  static Future<bool> tabsSelect(List<dynamic> args) async {
    final id = args.isEmpty ? null : PluginArgs.string(args.first is Map ? (args.first as Map)['id'] : args.first);
    if (id == null) {
      throw const TimelineHostError('tabs.select needs a tab id');
    }
    return TimelineRegistry.tabShell?.selectTab(id) ?? false;
  }
}
