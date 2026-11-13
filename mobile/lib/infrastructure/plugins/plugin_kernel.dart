import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';
import 'package:immich_mobile/domain/plugins/plugin_hook_runner.dart';
import 'package:immich_mobile/domain/plugins/plugin_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/device_workflow_engine.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_asset_data.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_tasks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_toggles.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_ui_surfaces.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

export 'package:immich_mobile/domain/models/device_plugin.model.dart';
export 'package:immich_mobile/domain/plugins/plugin_hook_runner.dart'
    show PluginCancelled, PluginHookHandler, PluginThrottle;
export 'package:immich_mobile/domain/plugins/plugin_ids.dart';
export 'package:immich_mobile/infrastructure/plugins/device_workflow_engine.dart' show HostFunction, HostFunctionException;
export 'package:immich_mobile/infrastructure/plugins/plugin_asset_data.dart';
export 'package:immich_mobile/infrastructure/plugins/plugin_tasks.dart';
export 'package:immich_mobile/infrastructure/plugins/plugin_toggles.dart';
export 'package:immich_mobile/infrastructure/plugins/plugin_ui_surfaces.dart';

/// Runs an app command (`toast`, `openUiPage`, `dialog`, ...) for [plugin]. Set by the presentation layer
/// (`performPluginUiAction`); [context] is the widget that triggered it, when there is one.
typedef PluginCommandHandler =
    Future<Object?> Function(String plugin, Map<String, dynamic> command, BuildContext? context);

/// An event as Dart listeners see it ([PluginKernel.listen]).
class PluginEvent {
  final String name;
  final Map<String, dynamic> data;

  /// The plugin that emitted it (`host.emit` / `events.emit`), or null for app events.
  final String? source;

  const PluginEvent(this.name, this.data, {this.source});
}

/// Introspection entry for `kernel.slots`, `kernel.hooks`, `kernel.events` and `kernel.hostFunctions`.
class PluginCatalogEntry {
  final String id;

  /// `slot`, `hook`, `event` or `host`.
  final String kind;
  final String? area;
  final String? doc;
  final Map<String, dynamic> details;

  const PluginCatalogEntry({required this.id, required this.kind, this.area, this.doc, this.details = const {}});

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    if (area != null) 'area': area,
    if (doc != null) 'doc': doc,
    ...details,
  };
}

class _HostEntry {
  final HostFunction handler;
  final String? doc;
  final String? area;

  const _HostEntry(this.handler, this.doc, this.area);
}

class _Subscription {
  final String plugin;
  final String pattern;
  final String method;
  final Duration? throttle;

  const _Subscription(this.plugin, this.pattern, this.method, this.throttle);
}

class _Listener {
  final String pattern;
  final void Function(PluginEvent event) callback;

  _Listener(this.pattern, this.callback);
}

class _SlotContent {
  Map<String, dynamic>? ui;
  Future<Map<String, dynamic>?>? pending;
  var resolved = false;
}

/// The plugin kernel: the one place plugins plug into the app (plan section 3).
///
/// * **Contributions**: slot items (filtered by `when`), built-in hide/order/rename rules, tools, tabs, settings
///   pages, theme and string overrides, all indexed from the enabled plugins' manifests.
/// * **Hooks** ([run], [runVoid], [tryRun]): `before` / `instead` / `after` plugin handlers around any app
///   operation, with priorities, per-hook timeouts and error isolation.
/// * **Events** ([emit], [listen]): delivered to plugin subscriptions (exact, `prefix.*`, `*`) without blocking.
/// * **Host functions** ([registerHost]): everything plugins can call with `host.callHost(name, argsJson)`.
/// * **State** for plugins: [toggles], [tasks], [assetData], JSON UI [surfaces] and native [views].
///
/// Everything is free while no plugin uses it: [hasHook] / [hasListeners] are map lookups and [run] calls the
/// original directly when no handler exists.
/// Holds the widget that triggered a command; [context] is null once it is unmounted, so it can be carried across
/// awaits safely.
class _Origin {
  final BuildContext _context;

  _Origin(this._context);

  BuildContext? get context => _context.mounted ? _context : null;
}

/// The kernel as the data layer's [PluginHookBinding] (`PluginHooks.bind(kernel.hookBinding)`). A separate object
/// because `ChangeNotifier.hasListeners` (a getter) clashes with `PluginHookBinding.hasListeners(event)`.
class _KernelHookBinding implements PluginHookBinding {
  final PluginKernel _kernel;

  const _KernelHookBinding(this._kernel);

  @override
  bool hasHook(String hookId) => _kernel.hasHook(hookId);

  @override
  bool hasListeners(String event) => _kernel.hasListenersFor(event);

  @override
  Future<T> run<T>(
    String hookId,
    PluginHookArgs args,
    Future<T> Function(PluginHookArgs args) original, {
    Object? Function(T value)? encode,
    T Function(Object? json)? decode,
  }) => _kernel.run<T>(hookId, args, original, encode: encode, decode: decode);

  @override
  void emit(String event, Map<String, dynamic> data) => _kernel.emit(event, data);

  @override
  bool isCancellation(Object error) => error is PluginCancelled;

  @override
  String? cancellationMessage(Object error) => error is PluginCancelled ? error.message : null;
}

class PluginKernel extends ChangeNotifier {
  /// Version of the kernel API (`app.info` `kernelApi`).
  static const apiVersion = 2;
  static const defaultHookTimeout = PluginHookChain.defaultTimeout;
  static const defaultEventTimeout = Duration(seconds: 30);
  static const _stateFile = 'kernel.json';
  static const _maxContentCache = 400;

  /// The kernel of the running app (set by `pluginKernelProvider`), for code without a Riverpod ref.
  static PluginKernel? current;

  final DeviceWorkflowEngine engine;
  final _log = Logger('PluginKernel');

  final toggles = PluginToggles();
  final tasks = PluginTasks();
  late final assetData = PluginAssetData(_root);
  final surfaces = PluginUiSurfaces();
  final views = PluginViewInstances();

  /// This kernel as the data layer's `PluginHookBinding` (bound with `PluginHooks.bind` at startup).
  late final PluginHookBinding hookBinding = _KernelHookBinding(this);

  /// Runs UI commands; set by the presentation layer at startup.
  PluginCommandHandler? commandHandler;

  /// The current route name (kept by the navigation observer); slot contexts get it as `route`.
  String? currentRoute;

  List<DevicePlugin> _plugins = const [];
  Map<String, List<SlotContribution>> _slots = const {};
  final Map<String, List<SlotContribution>> _runtimeSlots = {};
  final Map<String, Set<String>> _aliases = {};
  final Map<String, List<SlotContribution>> _mergedSlots = {};
  Map<String, BuiltinRules> _builtins = const {};
  Map<String, List<PluginHookHandler>> _hooks = const {};
  List<PluginHookHandler> _patternHooks = const [];
  List<_Subscription> _subscriptions = const [];
  List<ToolContribution> _tools = const [];
  List<TabContribution> _tabs = const [];
  List<SettingsContribution> _settings = const [];
  ThemeOverride? _manifestTheme;
  final Map<String, ThemeOverride> _runtimeThemes = {};
  Map<String, Map<String, String>> _strings = const {};

  final Map<String, bool> _hookCache = {};
  final Map<String, bool> _listenerCache = {};
  final LinkedHashMap<String, _SlotContent> _content = LinkedHashMap();
  final Map<String, PluginThrottle<Map<String, dynamic>>> _throttles = {};
  final Map<String, Future<void>> _eventQueues = {};
  final List<(String, Map<String, dynamic>, String?)> _earlyEvents = [];
  final List<_Listener> _listeners = [];
  final Map<String, _HostEntry> _host = {};
  final Map<String, PluginCommandHandler> _commands = {};
  final Map<String, PluginCatalogEntry> _catalog = {};

  /// Bumps whenever the set of hook handlers changes (plugins enabled, disabled, installed, updated).
  final hooksRevision = ValueNotifier<int>(0);
  final _hookChanges = StreamController<Set<String>>.broadcast();
  final _unloaded = StreamController<String>.broadcast();
  Map<String, int> _hookSignatures = const {};

  var _indexed = false;
  var _generation = 0;
  StreamSubscription<void>? _engineChanges;
  Future<void>? _started;
  Timer? _saveTimer;

  PluginKernel(this.engine) {
    engine.hostLookup = _lookupHost;
    engine.eventBus = emit;
    engine.uiHandler = (plugin, action) => command(plugin, action);
    engine.runtime.emitHandler = (plugin, event, payload) async => emit(event, _decodeMap(payload), source: plugin);
    _engineChanges = engine.changes.listen((_) => unawaited(_reindex()));
    toggles
      ..emit = emit
      ..persist = (_) async => _scheduleSave();
    tasks.emit = emit;
    assetData.emit = emit;
    _registerKernelApi();
  }

  /// Loads kernel state, initializes the plugin engine and builds the contribution index. Idempotent.
  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    await _loadState();
    await engine.ensureReady();
    await _reindex();
  }

  /// Whether the contribution index has been built at least once.
  bool get isReady => _indexed;

  Future<Directory> _root() async => Directory(await engine.pluginsRoot());

  /// A plugin's private data folder (created if missing): the folder `readFile` / `writeFile` / `getStorage` and
  /// `assetData` use; relative plugin paths resolve inside it.
  Future<Directory> pluginDataDir(String plugin) async {
    final directory = Directory(p.join((await _root()).path, 'data', plugin));
    await directory.create(recursive: true);
    return directory;
  }

  /// Names of plugins that were disabled, uninstalled or replaced (stop their downloads, timers, ...).
  Stream<String> get pluginUnloaded => _unloaded.stream;

  // ---------------------------------------------------------------------------------------------------------------
  // Index
  // ---------------------------------------------------------------------------------------------------------------

  /// Enabled, loaded plugins in display order.
  List<DevicePlugin> get plugins => _plugins;

  DevicePlugin? plugin(String name) => _plugins.where((plugin) => plugin.name == name).firstOrNull;

  /// Rebuilds the index now (normally automatic on install, enable, disable and the `refresh` command).
  Future<void> refresh() => _reindex();

  Future<void> _reindex() async {
    final generation = ++_generation;
    final List<DevicePlugin> plugins;
    try {
      plugins = await engine.activePlugins();
    } catch (error, stack) {
      _log.severe('Unable to index plugins', error, stack);
      return;
    }
    if (generation != _generation) {
      return;
    }
    _applyIndex(plugins);
  }

  void _applyIndex(List<DevicePlugin> plugins) {
    final names = {for (final plugin in plugins) plugin.name};
    final rank = {for (final (index, plugin) in plugins.indexed) plugin.name: index};
    _runtimeSlots.removeWhere((name, _) => !names.contains(name));

    final slots = <String, List<SlotContribution>>{};
    final builtins = <String, BuiltinRules>{};
    final hooks = <String, List<PluginHookHandler>>{};
    final patternHooks = <PluginHookHandler>[];
    final subscriptions = <_Subscription>[];
    final tools = <ToolContribution>[];
    final tabs = <TabContribution>[];
    final settings = <SettingsContribution>[];
    final strings = <String, Map<String, String>>{};
    final toggleDefaults = <String, bool>{};
    ThemeOverride? theme;

    for (final plugin in plugins) {
      for (final item in [...plugin.slots, ...?_runtimeSlots[plugin.name]]) {
        slots.putIfAbsent(item.slot, () => []).add(item);
        if (item.isToggle) {
          toggleDefaults[item.toggleKey] = item.defaultValue;
        }
      }
      for (final MapEntry(:key, :value) in plugin.builtins.entries) {
        builtins[key] = (builtins[key] ?? BuiltinRules.empty).merge(value);
      }
      for (final handler in plugin.hooks) {
        handler.hook.contains('*') ? patternHooks.add(handler) : hooks.putIfAbsent(handler.hook, () => []).add(handler);
      }
      for (final MapEntry(key: pattern, value: method) in plugin.events.entries) {
        final throttle = plugin.eventThrottleMs[pattern];
        subscriptions.add(
          _Subscription(
            plugin.name,
            pattern,
            method,
            throttle == null || throttle <= 0 ? null : Duration(milliseconds: throttle),
          ),
        );
      }
      tools.addAll(plugin.tools);
      tabs.addAll(plugin.tabs);
      settings.addAll(plugin.settings);
      if (plugin.theme != null && !plugin.theme!.isEmpty) {
        theme = (theme ?? const ThemeOverride()).merge(plugin.theme);
      }
      for (final MapEntry(:key, :value) in plugin.strings.entries) {
        strings.putIfAbsent(_normalizeLocale(key), () => {}).addAll(value);
      }
    }

    int byOrder(int orderA, String pluginA, int indexA, int orderB, String pluginB, int indexB) {
      final order = orderA.compareTo(orderB);
      if (order != 0) {
        return order;
      }
      final byPlugin = (rank[pluginA] ?? 0).compareTo(rank[pluginB] ?? 0);
      return byPlugin != 0 ? byPlugin : indexA.compareTo(indexB);
    }

    for (final list in slots.values) {
      list.sort((a, b) => byOrder(a.order, a.plugin, a.index, b.order, b.plugin, b.index));
    }
    tools.sort((a, b) => byOrder(a.order, a.plugin, a.index, b.order, b.plugin, b.index));
    tabs.sort((a, b) => byOrder(a.order, a.plugin, a.index, b.order, b.plugin, b.index));

    final unloaded = [
      for (final plugin in _plugins)
        if (!names.contains(plugin.name)) plugin.name,
    ];
    for (final plugin in unloaded) {
      tasks.abandon(plugin);
      _runtimeThemes.remove(plugin);
    }
    _throttles.removeWhere((key, throttle) {
      final remove = !names.contains(key.split('\n').first);
      if (remove) {
        throttle.dispose();
      }
      return remove;
    });

    final signatures = <String, int>{
      for (final MapEntry(:key, :value) in hooks.entries) key: jsonHash([for (final handler in value) handler.toJson()]),
      for (final handler in patternHooks) handler.hook: jsonHash(handler.toJson()),
    };
    final changedHooks = {
      for (final id in {...signatures.keys, ..._hookSignatures.keys})
        if (signatures[id] != _hookSignatures[id]) id,
    };
    _hookSignatures = signatures;

    _plugins = plugins;
    _slots = slots;
    _builtins = builtins;
    _hooks = hooks;
    _patternHooks = patternHooks;
    _subscriptions = subscriptions;
    _tools = tools;
    _tabs = tabs;
    _settings = settings;
    _manifestTheme = theme;
    _strings = strings;
    toggles.definePluginDefaults(toggleDefaults);
    _mergedSlots.clear();
    _hookCache.clear();
    _listenerCache.clear();
    _content.clear();

    final firstIndex = !_indexed;
    _indexed = true;
    notifyListeners();
    if (changedHooks.isNotEmpty) {
      hooksRevision.value++;
      _hookChanges.add(changedHooks);
    }
    unloaded.forEach(_unloaded.add);
    if (firstIndex) {
      final early = List.of(_earlyEvents);
      _earlyEvents.clear();
      for (final (event, data, source) in early) {
        emit(event, data, source: source);
      }
    }
  }

  static String _normalizeLocale(String locale) => locale.replaceAll('-', '_');

  // ---------------------------------------------------------------------------------------------------------------
  // Contributions
  // ---------------------------------------------------------------------------------------------------------------

  /// Contributions declared for [legacyOrAlias] also show in [slotId] (e.g. the legacy `main.appBar` in
  /// `mainTimeline.appBar.actions`). Areas call this from their `register<Area>PluginApi`.
  void aliasSlot(String legacyOrAlias, String slotId) {
    if (legacyOrAlias == slotId) {
      return;
    }
    _aliases.putIfAbsent(slotId, () => {}).add(legacyOrAlias);
    _mergedSlots.clear();
    notifyListeners();
  }

  List<SlotContribution> _itemsOf(String slotId) {
    final aliases = _aliases[slotId];
    if (aliases == null) {
      return _slots[slotId] ?? const [];
    }
    return _mergedSlots.putIfAbsent(slotId, () {
      final merged = [...?_slots[slotId], for (final alias in aliases) ...?_slots[alias]];
      final rank = {for (final (index, plugin) in _plugins.indexed) plugin.name: index};
      merged.sort((a, b) {
        final order = a.order.compareTo(b.order);
        if (order != 0) {
          return order;
        }
        final byPlugin = (rank[a.plugin] ?? 0).compareTo(rank[b.plugin] ?? 0);
        return byPlugin != 0 ? byPlugin : a.index.compareTo(b.index);
      });
      return merged;
    });
  }

  /// Whether any plugin contributes to [slotId] (before `when` filtering). O(1) map lookup; use it on hot paths
  /// (every tile build) to skip building slot context.
  bool hasSlot(String slotId) => _itemsOf(slotId).isNotEmpty;

  /// Same as [hasSlot].
  bool hasContributions(String slotId) => hasSlot(slotId);

  /// The items plugins contribute to [slotId] whose `when` matches [context], in display order.
  ///
  /// [context] holds JSON values describing where the slot is (asset fields, album id, ...); the kernel adds `route`,
  /// `platform` and `slot`, and derives `assetType`, `isVideo`, ... from `asset` / `assets` AssetV1 entries (see
  /// [assetContext] for building them from [BaseAsset]s synchronously).
  List<SlotContribution> slot(String slotId, {Map<String, dynamic> context = const {}}) {
    final items = _itemsOf(slotId);
    if (items.isEmpty) {
      return const [];
    }
    if (items.every((item) => item.when == null)) {
      return items;
    }
    final full = slotContext(slotId, context);
    return [
      for (final item in items)
        if (matchesWhen(item.when, full)) item,
    ];
  }

  /// [context] with the kernel's keys added (as matched by `when` and sent to plugins in `SlotV1`).
  Map<String, dynamic> slotContext(String slotId, Map<String, dynamic> context) => {
    'slot': slotId,
    'route': currentRoute,
    'platform': Platform.operatingSystem,
    ...PluginContextKeys.derive(context),
  };

  /// Slot context fields for [assets], computed synchronously: `assetId`, `assetIds` (up to 100), `assetType`,
  /// `isVideo`, `isImage`, `isLocal`, `isRemote`, `isFavorite`, `selectionCount`.
  static Map<String, dynamic> assetContext(List<BaseAsset> assets) {
    if (assets.isEmpty) {
      return const {'selectionCount': 0};
    }
    final first = assets.first;
    return {
      'assetId': first.id,
      if (assets.length > 1) 'assetIds': [for (final asset in assets.take(100)) asset.id],
      'assetType': switch (first.type) {
        AssetType.image => 'IMAGE',
        AssetType.video => 'VIDEO',
        AssetType.audio => 'AUDIO',
        AssetType.other => 'OTHER',
      },
      'isVideo': first.isVideo,
      'isImage': first.isImage,
      'isLocal': first.hasLocal,
      'isRemote': first.hasRemote,
      'isFavorite': first.isFavorite,
      'selectionCount': assets.length,
    };
  }

  /// Hide / order / rename / icon rules plugins set for the built-in items of [slotId].
  BuiltinRules builtins(String slotId) {
    final direct = _builtins[slotId];
    final aliases = _aliases[slotId];
    if (aliases == null) {
      return direct ?? BuiltinRules.empty;
    }
    return aliases.fold(
      direct ?? BuiltinRules.empty,
      (rules, alias) => rules.merge(_builtins[alias] ?? BuiltinRules.empty),
    );
  }

  /// Tools for a tool surface (`editor.image`, `editor.video`, ...), filtered by `when`.
  List<ToolContribution> tools(String surface, {Map<String, dynamic> context = const {}}) => [
    for (final tool in _tools)
      if (tool.surface == surface && (tool.when == null || matchesWhen(tool.when, slotContext(surface, context)))) tool,
  ];

  /// Bottom navigation tabs contributed by plugins, by `order`.
  List<TabContribution> get tabs => _tabs;

  /// Plugin settings pages (Settings and the Plugins page list them).
  List<SettingsContribution> get settingsPages => _settings;

  /// Theme override merged from manifests (plugin order, later wins per key) and `setTheme` commands; null if none.
  ThemeOverride? get themeOverride {
    var theme = _manifestTheme;
    for (final runtime in _runtimeThemes.values) {
      theme = (theme ?? const ThemeOverride()).merge(runtime);
    }
    return theme == null || theme.isEmpty ? null : theme;
  }

  /// String overrides for [locale] (`en`, `en_US`, `pt-BR`): language entries, then region entries over them.
  /// Every string override of the enabled plugins, by locale (`*` for any locale).
  Map<String, Map<String, String>> get stringOverrides => _strings;

  Map<String, String> strings(String locale) {
    if (_strings.isEmpty) {
      return const {};
    }
    final normalized = _normalizeLocale(locale);
    final language = normalized.split('_').first;
    return {...?_strings['*'], ...?_strings[language], if (normalized != language) ...?_strings[normalized]};
  }

  /// One string override, or [fallback].
  String string(String locale, String key, String fallback) => strings(locale)[key] ?? fallback;

  // ---------------------------------------------------------------------------------------------------------------
  // Slot content and taps
  // ---------------------------------------------------------------------------------------------------------------

  /// The JSON UI surface id of [item]'s content in [context]: `slot:<slot>/<id>` (or the item's `surface`), plus
  /// `#<assetId>` when the context is about one asset, so per-asset content (tile badges) can be updated one by one.
  static String slotSurfaceId(SlotContribution item, Map<String, dynamic> context) {
    final assetId = context['assetId'];
    return assetId == null ? item.surfaceId : '${item.surfaceId}#$assetId';
  }

  String _contentKey(SlotContribution item, Map<String, dynamic> context) =>
      '${item.slot}\n${item.plugin}\n${item.id}\n${jsonHash(context)}';

  /// The `uiMethod` content of [item] for [context] if it was fetched already (null while loading or failed).
  Map<String, dynamic>? cachedSlotUi(SlotContribution item, {Map<String, dynamic> context = const {}}) {
    if (item.ui != null) {
      return item.ui;
    }
    return _content[_contentKey(item, context)]?.ui;
  }

  /// Whether [cachedSlotUi] is final for [context] (fetched, even if empty or failed).
  bool isSlotUiResolved(SlotContribution item, {Map<String, dynamic> context = const {}}) =>
      item.ui != null || (_content[_contentKey(item, context)]?.resolved ?? false);

  /// The JSON UI content of [item]: its static `ui`, or the `{ "ui" }` its `uiMethod` returns for `SlotV1`
  /// (`event: "content"`), cached per slot, plugin, item and context until [refreshSlots].
  Future<Map<String, dynamic>?> slotUi(
    SlotContribution item, {
    Map<String, dynamic> context = const {},
    List<BaseAsset> assets = const [],
  }) {
    final staticUi = item.ui;
    final method = item.uiMethod;
    if (staticUi != null || method == null) {
      return SynchronousFuture(staticUi);
    }
    final key = _contentKey(item, context);
    final entry = _content.remove(key) ?? _SlotContent();
    _content[key] = entry;
    while (_content.length > _maxContentCache) {
      _content.remove(_content.keys.first);
    }
    if (entry.resolved) {
      return SynchronousFuture(entry.ui);
    }
    return entry.pending ??= () async {
      try {
        final response = await call(item.plugin, method, PluginCallType.slot, {
          'slot': item.slot,
          'id': item.id,
          'event': 'content',
          'surface': slotSurfaceId(item, context),
          'context': slotContext(item.slot, context),
          if (assets.isNotEmpty) 'assets': [for (final asset in assets) await assetJson(asset)],
        }, config: item.params);
        final ui = response?['ui'];
        entry.ui = ui is Map ? Map<String, dynamic>.from(ui) : null;
      } catch (error, stack) {
        _log.warning('Slot content ${item.plugin}/${item.id} in ${item.slot} failed', error, stack);
        entry.ui = null;
      }
      entry
        ..resolved = true
        ..pending = null;
      return entry.ui;
    }();
  }

  /// Drops cached `uiMethod` content (of one slot, or all) so slots fetch it again.
  void refreshSlots([String? slotId]) {
    if (slotId == null) {
      _content.clear();
    } else {
      _content.removeWhere((key, _) => key.startsWith('$slotId\n'));
    }
    notifyListeners();
  }

  /// Runs a slot item tap (or a `toggle` flip): calls its `method` with `SlotV1`
  /// (`{ "slot", "id", "event": "tap" | "toggle", "value"?, "context", "surface", "assets"? }`) and performs the
  /// response; items without a method open their `view` (native page) or `ui` / `uiMethod` (JSON UI page). Legacy
  /// `buttons` / `pages` keep their v1 behaviour (`ButtonV1`). Errors propagate to the caller.
  Future<void> runSlot(
    SlotContribution item, {
    Map<String, dynamic> context = const {},
    List<BaseAsset> assets = const [],
    BuildContext? buildContext,
    String event = 'tap',
    Object? value,
  }) async {
    final origin = buildContext == null ? null : _Origin(buildContext);
    final method = item.method;
    if (item.isLegacy) {
      if (method == null) {
        if (item.view != null) {
          await command(item.plugin, {
            'type': 'openPage',
            'view': item.view,
            'title': item.title,
            'params': item.params,
          }, context: origin?.context);
        }
        return;
      }
      final response = await call(
        item.plugin,
        method,
        PluginCallType.button,
        {
          'slot': item.slot,
          'assets': [for (final asset in assets) await assetJson(asset)],
        },
        config: item.params,
        workflow: {'id': 'button', 'stepId': item.id},
      );
      await perform(item.plugin, response, context: origin?.context);
      return;
    }

    var eventName = event;
    var eventValue = value;
    if (item.isToggle && event == 'tap') {
      eventValue = await toggles.toggle(item.toggleKey, source: item.plugin);
      eventName = 'toggle';
    }
    if (method != null) {
      final response = await call(item.plugin, method, PluginCallType.slot, {
        'slot': item.slot,
        'id': item.id,
        'event': eventName,
        'value': ?eventValue,
        'surface': slotSurfaceId(item, context),
        'context': slotContext(item.slot, context),
        if (assets.isNotEmpty) 'assets': [for (final asset in assets) await assetJson(asset)],
      }, config: item.params);
      await perform(item.plugin, _withMethod(response, method), context: origin?.context);
      return;
    }
    if (item.isToggle) {
      return;
    }
    if (item.view != null) {
      await command(item.plugin, {
        'type': 'openPage',
        'view': item.view,
        'title': item.title,
        'params': item.params,
        'composition': ?item.composition,
      }, context: origin?.context);
    } else if (item.uiMethod != null || item.ui != null) {
      await command(item.plugin, {
        'type': 'openUiPage',
        'title': item.title,
        'page': item.id,
        'method': ?item.uiMethod,
        'ui': ?item.ui,
        'params': {...item.params, 'context': slotContext(item.slot, context)},
        'surface': item.surfaceId,
      }, context: origin?.context);
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Hooks
  // ---------------------------------------------------------------------------------------------------------------

  /// Declares a hook for introspection (`kernel.hooks`) and sets its behaviour: [cancellable] false ignores
  /// `{ "cancel": true }`; [timeout] is the default for handlers without `timeoutMs`.
  void declareHook(
    String hookId, {
    bool cancellable = true,
    Duration? timeout,
    String? doc,
    Object? args,
    Object? result,
    String? area,
  }) {
    _catalog['hook:$hookId'] = PluginCatalogEntry(
      id: hookId,
      kind: 'hook',
      area: area,
      doc: doc,
      details: {
        'cancellable': cancellable,
        if (timeout != null) 'timeoutMs': timeout.inMilliseconds,
        'args': ?args,
        'result': ?result,
      },
    );
  }

  bool hasHook(String hookId) => _hookCache.putIfAbsent(
    hookId,
    () =>
        (_hooks[hookId]?.isNotEmpty ?? false) ||
        _patternHooks.any((handler) => matchesEventPattern(handler.hook, hookId)),
  );

  /// Hook ids whose handlers changed in the last re-index, each time the set changes (see also [hooksRevision]).
  Stream<Set<String>> get hookChanges => _hookChanges.stream;

  /// Identifies the handlers of [hookId]: `plugin@version:phase` per handler, comma separated, empty without
  /// handlers. Changes whenever a handler is added, removed or its plugin updated (use it in cache keys).
  String hookSignature(String hookId) {
    if (!hasHook(hookId)) {
      return '';
    }
    final versions = {for (final plugin in _plugins) plugin.name: plugin.version};
    return [
      for (final handler in _handlersOf(hookId))
        '${handler.plugin}@${versions[handler.plugin] ?? '?'}:${handler.phase.name}',
    ].join(',');
  }

  /// Whether a handler of [hookId] applies to a call with [args] (its manifest `when` matches them).
  bool hasHookFor(String hookId, Map<String, dynamic> args) =>
      hasHook(hookId) && _handlersOf(hookId).any((handler) => handler.appliesTo(args));

  List<PluginHookHandler> _handlersOf(String hookId) => [
    ...?_hooks[hookId],
    for (final handler in _patternHooks)
      if (matchesEventPattern(handler.hook, hookId)) handler,
  ];

  /// Runs [original] wrapped by every plugin handler of [hookId] (see [PluginHookChain] for the phases).
  ///
  /// [args] must be JSON values. Without handlers this is exactly `original(args)`. A `before` (or `instead`)
  /// handler returning `{ "cancel": true, "message"? }` makes this throw [PluginCancelled]; every other plugin
  /// failure or timeout is logged and the chain continues as if the handler did not exist. Errors thrown by
  /// [original] propagate unchanged. [encode] / [decode] convert the result for `instead` / `after` handlers
  /// (without [decode] a plugin result is used only when it already has type [T]).
  Future<T> run<T>(
    String hookId,
    Map<String, dynamic> args,
    Future<T> Function(Map<String, dynamic> args) original, {
    Object? Function(T value)? encode,
    T Function(Object? json)? decode,
  }) {
    if (!hasHook(hookId)) {
      return original(args);
    }
    final handlers = [
      for (final handler in _handlersOf(hookId))
        if (handler.appliesTo(args)) handler,
    ];
    if (handlers.isEmpty) {
      return original(args);
    }
    final declared = _catalog['hook:$hookId']?.details;
    final timeoutMs = declared?['timeoutMs'];
    final chain = PluginHookChain(
      hook: hookId,
      bindings: handlers,
      invoke: _invokeHook,
      onError: (handler, error, stack) =>
          _log.warning('Hook $hookId (${handler.phase.name}) of ${handler.plugin} failed', error, stack),
      timeout: timeoutMs is int ? Duration(milliseconds: timeoutMs) : defaultHookTimeout,
      cancellable: declared?['cancellable'] != false,
    );
    return chain.run<T>(args, original, encode: encode, decode: decode);
  }

  Future<Map<String, dynamic>?> _invokeHook(PluginHookHandler handler, Map<String, dynamic> data) =>
      call(handler.plugin, handler.method, PluginCallType.hook, data, workflow: {'id': 'hook', 'stepId': handler.hook});

  /// Fire-and-forget [run] for synchronous call sites (void actions). Without handlers [original] runs synchronously,
  /// exactly as before. With handlers it runs after the chain; a cancellation shows its message as a snackbar.
  void runVoid(
    String hookId,
    Map<String, dynamic> args,
    FutureOr<void> Function(Map<String, dynamic> args) original,
  ) {
    if (!hasHook(hookId)) {
      final result = original(args);
      if (result is Future) {
        unawaited(result);
      }
      return;
    }
    unawaited(
      tryRun<void>(hookId, args, (args) async => original(args)).catchError((Object error, StackTrace stack) {
        _log.severe('$hookId failed', error, stack);
      }),
    );
  }

  /// [run] that shows a cancellation's message (snackbar) and returns null instead of throwing [PluginCancelled].
  Future<T?> tryRun<T>(
    String hookId,
    Map<String, dynamic> args,
    Future<T> Function(Map<String, dynamic> args) original, {
    Object? Function(T value)? encode,
    T Function(Object? json)? decode,
    BuildContext? context,
  }) async {
    try {
      return await run<T>(hookId, args, original, encode: encode, decode: decode);
    } on PluginCancelled catch (cancelled) {
      showCancelled(cancelled, context: context);
      return null;
    }
  }

  /// Shows a [PluginCancelled] message (if it has one) as a snackbar.
  void showCancelled(PluginCancelled cancelled, {BuildContext? context}) {
    final message = cancelled.message;
    if (message != null) {
      unawaited(command(cancelled.plugin, {'type': 'snackbar', 'message': message}, context: context));
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------------------------------------------

  /// Declares an event for introspection (`kernel.events`); [throttle] rate limits its delivery per subscriber
  /// (manifest `throttleMs` overrides it).
  void declareEvent(String event, {Duration? throttle, String? doc, Object? payload, String? area}) {
    _catalog['event:$event'] = PluginCatalogEntry(
      id: event,
      kind: 'event',
      area: area,
      doc: doc,
      details: {if (throttle != null) 'throttleMs': throttle.inMilliseconds, 'payload': ?payload},
    );
  }

  Duration? _declaredThrottle(String event) {
    final throttle = _catalog['event:$event']?.details['throttleMs'];
    return throttle is int && throttle > 0 ? Duration(milliseconds: throttle) : null;
  }

  /// Whether a plugin subscription or a Dart listener matches [event]. Use it before building expensive payloads.
  bool hasListenersFor(String event) => _listenerCache.putIfAbsent(
    event,
    () =>
        _subscriptions.any((subscription) => matchesEventPattern(subscription.pattern, event)) ||
        _listeners.any((listener) => matchesEventPattern(listener.pattern, event)),
  );

  /// Delivers [event] to Dart listeners and to plugins whose manifest `events` match it (exactly, `prefix.*` or
  /// `*`), as `EventV1` `{ "event", ...data, "source"? }`. Never blocks: deliveries run later, in order per plugin,
  /// and their responses (`message`, `actions`) are performed. [source] is the emitting plugin (it does not receive
  /// its own event). Events emitted before the first index are queued.
  void emit(String event, Map<String, dynamic> data, {String? source}) {
    if (!_indexed) {
      if (_earlyEvents.length < 256) {
        _earlyEvents.add((event, data, source));
      }
      return;
    }
    for (final listener in List.of(_listeners)) {
      if (matchesEventPattern(listener.pattern, event)) {
        scheduleMicrotask(() {
          try {
            listener.callback(PluginEvent(event, data, source: source));
          } catch (error, stack) {
            _log.warning('Listener for $event failed', error, stack);
          }
        });
      }
    }
    for (final subscription in _subscriptions) {
      if (subscription.plugin == source || !matchesEventPattern(subscription.pattern, event)) {
        continue;
      }
      final throttle = subscription.throttle ?? _declaredThrottle(event);
      if (throttle == null) {
        _enqueue(subscription, event, data, source);
        continue;
      }
      final key = '${subscription.plugin}\n${subscription.method}\n$event';
      (_throttles[key] ??= PluginThrottle<Map<String, dynamic>>(
        interval: throttle,
        deliver: (_, value) => _enqueue(subscription, event, value, source),
      )).add(key, data);
    }
  }

  /// Calls [callback] for every event matching [pattern] (exact, `prefix.*` or `*`). Returns a function that stops it.
  void Function() listen(String pattern, void Function(PluginEvent event) callback) {
    final listener = _Listener(pattern, callback);
    _listeners.add(listener);
    _listenerCache.clear();
    return () {
      _listeners.remove(listener);
      _listenerCache.clear();
    };
  }

  void _enqueue(_Subscription subscription, String event, Map<String, dynamic> data, String? source) {
    final plugin = subscription.plugin;
    final previous = _eventQueues[plugin] ?? Future<void>.value();
    final next = previous.then((_) => _deliver(subscription, event, data, source));
    _eventQueues[plugin] = next;
    unawaited(
      next.whenComplete(() {
        if (identical(_eventQueues[plugin], next)) {
          unawaited(_eventQueues.remove(plugin));
        }
      }),
    );
  }

  Future<void> _deliver(_Subscription subscription, String event, Map<String, dynamic> data, String? source) async {
    try {
      final response = await call(
        subscription.plugin,
        subscription.method,
        PluginCallType.event,
        {'event': event, ...data, 'source': ?source},
        workflow: {'id': 'event', 'stepId': event},
        timeout: defaultEventTimeout,
      );
      await perform(subscription.plugin, _withMethod(response, subscription.method));
    } catch (error, stack) {
      _log.warning('Plugin ${subscription.plugin} failed on $event', error, stack);
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Host functions
  // ---------------------------------------------------------------------------------------------------------------

  /// Makes [name] callable by plugins (`host.callHost(name, argsJson)` / `callHostAsync`). Names are
  /// `<namespace>.<verb>`; registering an existing name (also a legacy one such as `getAsset`) replaces it.
  void registerHost(String name, HostFunction handler, {String? doc, String? area}) {
    _host[name] = _HostEntry(handler, doc, area);
  }

  void unregisterHost(String name) => _host.remove(name);

  bool hasHost(String name) => _host.containsKey(name);

  HostFunction? _lookupHost(String name) => _host[name]?.handler;

  /// Calls host function [name] from Dart as plugin [plugin] would (registered functions, then the legacy names).
  Future<Object?> callHost(String name, List<dynamic> args, {String plugin = appToggleOwner}) =>
      engine.dispatchHost(plugin, name, args);

  /// Declares a slot for introspection (`kernel.slots`): supported [kinds], [context] fields and [builtins] ids.
  void declareSlot(
    String slotId, {
    List<String> kinds = const [],
    List<String> context = const [],
    List<String> builtins = const [],
    String? doc,
    String? area,
  }) {
    _catalog['slot:$slotId'] = PluginCatalogEntry(
      id: slotId,
      kind: 'slot',
      area: area,
      doc: doc,
      details: {
        if (kinds.isNotEmpty) 'kinds': kinds,
        if (context.isNotEmpty) 'context': context,
        if (builtins.isNotEmpty) 'builtins': builtins,
      },
    );
  }

  /// Everything declared or used, for `kernel.slots` / `kernel.hooks` / `kernel.events` / `kernel.hostFunctions`.
  List<Map<String, dynamic>> catalog(String kind) {
    final entries = <String, Map<String, dynamic>>{
      for (final entry in _catalog.values)
        if (entry.kind == kind) entry.id: {...entry.toJson(), 'declared': true},
    };
    switch (kind) {
      case 'slot':
        for (final MapEntry(key: id, value: items) in _slots.entries) {
          (entries[id] ??= {'id': id, 'kind': 'slot', 'declared': false})['contributions'] = [
            for (final item in items) item.toJson(),
          ];
        }
        for (final MapEntry(key: slotId, value: aliases) in _aliases.entries) {
          (entries[slotId] ??= {'id': slotId, 'kind': 'slot', 'declared': false})['aliases'] = aliases.toList();
        }
      case 'hook':
        for (final handler in [for (final list in _hooks.values) ...list, ..._patternHooks]) {
          ((entries[handler.hook] ??= {'id': handler.hook, 'kind': 'hook', 'declared': false})['handlers'] ??=
                  <Map<String, dynamic>>[])
              .add(handler.toJson());
        }
      case 'event':
        for (final subscription in _subscriptions) {
          ((entries[subscription.pattern] ??= {'id': subscription.pattern, 'kind': 'event', 'declared': false})['subscribers'] ??=
                  <String>[])
              .add(subscription.plugin);
        }
      case 'host':
        for (final MapEntry(:key, :value) in _host.entries) {
          entries[key] = {'id': key, 'kind': 'host', 'area': ?value.area, 'doc': ?value.doc};
        }
    }
    return entries.values.toList();
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Calling plugins
  // ---------------------------------------------------------------------------------------------------------------

  /// Calls [method] of [plugin] with `{ "type", "config", "workflow", "data" }`; returns its JSON object response.
  Future<Map<String, dynamic>?> call(
    String plugin,
    String method,
    String type,
    Map<String, dynamic> data, {
    Map<String, dynamic> config = const {},
    Duration? timeout,
    Map<String, dynamic>? workflow,
  }) {
    final future = engine.callPluginMethod(plugin, method, {
      'type': type,
      'config': config,
      'workflow': {'id': workflow?['id'] ?? type, 'authToken': '', 'stepId': workflow?['stepId'] ?? method},
      'data': data,
    });
    return timeout == null ? future : future.timeout(timeout);
  }

  /// AssetV1 JSON for local and remote assets (superset: `isLocal`, `isRemote`, `localId`, `remoteId`, ...).
  Future<Map<String, dynamic>> assetJson(BaseAsset asset) => engine.assetJson(asset);

  /// Finds a local or remote asset by id.
  Future<BaseAsset?> findAsset(String id) => engine.findAsset(id);

  /// A response whose `ui` opens as a sheet sends that sheet's UI events to [method] unless it names another.
  static Map<String, dynamic>? _withMethod(Map<String, dynamic>? response, String method) =>
      response == null || response['ui'] == null || response.containsKey('method')
      ? response
      : {...response, 'method': method};

  /// Performs a plugin response: `ui` opens as a sheet, `actions` run as commands, `message` shows as a toast.
  Future<void> perform(String plugin, Map<String, dynamic>? response, {BuildContext? context}) async {
    if (response == null) {
      return;
    }
    final origin = context == null ? null : _Origin(context);
    final ui = response['ui'];
    if (ui is Map) {
      unawaited(
        command(plugin, {
          'type': 'sheet',
          'ui': ui,
          'title': ?response['title'],
          'method': ?response['method'],
          'surface': ?response['surface'],
        }, context: context),
      );
    }
    final actions = response['actions'];
    for (final action in (actions is List ? actions : const []).whereType<Map>()) {
      await command(plugin, Map<String, dynamic>.from(action), context: origin?.context);
    }
    final message = response['message'];
    if (message is String && message.isNotEmpty) {
      await command(plugin, {'type': 'toast', 'message': message}, context: origin?.context);
    }
  }

  /// Implements command [type] in area code (`toast`, `setTheme`, or a new one). Registered commands run before the
  /// kernel's own and the UI's, are reachable as `ui.<type>` host functions, and can be returned in `actions`.
  void registerCommand(String type, PluginCommandHandler handler, {String? doc, String? area}) {
    _commands[type] = handler;
    if (!_host.containsKey('ui.$type')) {
      registerHost('ui.$type', (plugin, args) {
        final first = _at(args, 0);
        return command(plugin, {...first is Map ? Map<String, dynamic>.from(first) : const {}, 'type': type});
      }, doc: doc ?? '[{ ...command fields }] -> command result', area: area);
    }
  }

  void unregisterCommand(String type) => _commands.remove(type);

  /// Runs one command for [plugin]. Commands registered with [registerCommand] run first; then the kernel's own
  /// (`refresh`, `refreshSlots`, `setTheme`, `setContentHeight`, `emit`, `uiUpdate`, `uiPatch`, `openSettings`);
  /// everything else goes to [commandHandler] (the app UI).
  Future<Object?> command(String plugin, Map<String, dynamic> command, {BuildContext? context}) async {
    final owner = '${command['plugin'] ?? plugin}';
    final registered = _commands[command['type']];
    if (registered != null) {
      final result = await registered(plugin, command, context);
      if (command['type'] == 'setTheme') {
        _applyRuntimeTheme(owner, command);
      }
      return result;
    }
    switch (command['type']) {
      case 'refresh':
        _content.clear();
        unawaited(_reindex());
      case 'refreshSlots':
        refreshSlots(command['slot'] as String?);
        return null;
      case 'setTheme':
        _applyRuntimeTheme(owner, command);
        return null;
      case 'openSettings':
        final target = '${command['id'] ?? command['page'] ?? ''}';
        final parsed = parsePluginItemId(target);
        return openSettingsPage(parsed?.$1 ?? owner, parsed?.$2 ?? target, context: context);
      case 'setContentHeight':
        final height = command['height'];
        return views.setHeight('${command['instance']}', height is num ? height.toDouble() : null);
      case 'emit':
        final data = command['data'] ?? command['payload'];
        emit(
          '${command['event']}',
          data is Map ? Map<String, dynamic>.from(data) : {'value': ?data},
          source: plugin,
        );
        return null;
      case 'uiUpdate':
        final tree = command['ui'];
        final state = command['state'];
        return surfaces.update(
          owner,
          '${command['surface']}',
          tree is Map ? Map<String, dynamic>.from(tree) : null,
          state: state is Map ? Map<String, dynamic>.from(state) : null,
        );
      case 'uiPatch':
        final props = command['props'];
        return surfaces.patch(
          owner,
          '${command['surface']}',
          '${command['node'] ?? command['id']}',
          props is Map ? Map<String, dynamic>.from(props) : const {},
        );
    }
    final handler = commandHandler;
    if (handler == null) {
      _log.info('No UI to run ${command['type']} for $plugin');
      return null;
    }
    return handler(plugin, command, context);
  }

  void _applyRuntimeTheme(String owner, Map<String, dynamic> command) {
    final theme = command['theme'] is Map ? command['theme'] : {...command}
      ..remove('type')
      ..remove('plugin');
    if (command['reset'] == true || theme is! Map || theme.isEmpty) {
      _runtimeThemes.remove(owner);
    } else {
      _runtimeThemes[owner] = ThemeOverride.fromJson(Map<String, dynamic>.from(theme));
    }
    notifyListeners();
  }

  /// The merged theme override as JSON (manifest themes, then `setTheme`), including keys the kernel does not model
  /// (`variant`, `contrast`, `fonts`, ...); empty when no plugin overrides the theme.
  Map<String, dynamic> get themeOverrideJson => themeOverride?.toJson() ?? const {};

  /// Absolute path of a file shipped in [plugin]'s zip (fonts, images, models).
  Future<String> pluginFile(String plugin, String path) async =>
      p.isAbsolute(path) ? path : p.join(await engine.pluginsRoot(), plugin, 'files', path);

  /// A settings page by plugin and id (`contributes.settings`); the first page of [plugin] when [id] is empty.
  SettingsContribution? settingsPage(String plugin, [String id = '']) => _settings
      .where((page) => page.plugin == plugin && (id.isEmpty || page.id == id))
      .firstOrNull;

  /// Opens a plugin settings page: its JSON UI page (`uiMethod`, live-updatable through surface `settings:<id>`) or
  /// its native `view`. Returns whether the page exists.
  Future<bool> openSettingsPage(String plugin, String id, {BuildContext? context}) async {
    final page = settingsPage(plugin, id);
    if (page == null) {
      return false;
    }
    final title = page.title;
    if (page.view != null) {
      unawaited(
        command(plugin, {
          'type': 'openPage',
          'view': page.view,
          'title': title,
          'params': page.params,
          'composition': ?page.composition,
        }, context: context),
      );
    } else {
      unawaited(
        command(plugin, {
          'type': 'openUiPage',
          'title': title,
          'method': page.uiMethod,
          'page': page.id,
          'params': page.params,
          'surface': 'settings:${page.id}',
        }, context: context),
      );
    }
    return true;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Kernel host functions
  // ---------------------------------------------------------------------------------------------------------------

  /// Commands reachable as `ui.<command>` host functions, with the field a single string argument fills.
  static const commandFields = <String, String?>{
    'toast': 'message',
    'snackbar': 'message',
    'openUrl': 'url',
    'openPage': 'view',
    'openUiPage': 'page',
    'closePage': null,
    'back': null,
    'navigate': 'path',
    'showOverlay': 'view',
    'hideOverlay': 'id',
    'refresh': null,
    'routes': null,
    'dialog': 'title',
    'sheet': 'title',
    'confirm': 'message',
    'prompt': 'title',
    'pickAssets': null,
    'pickAlbum': null,
    'pickDate': null,
    'openAsset': 'assetId',
    'openAlbum': 'albumId',
    'select': null,
    'clearSelection': null,
    'refreshSlots': 'slot',
    'setTheme': null,
    'haptic': 'style',
    'copy': 'text',
    'share': 'text',
    'setContentHeight': 'instance',
    'emit': 'event',
    'openSettings': 'id',
  };

  static Map<String, dynamic> _arg(List<dynamic> args, int index) =>
      index < args.length && args[index] is Map ? Map<String, dynamic>.from(args[index] as Map) : <String, dynamic>{};

  static String _text(List<dynamic> args, int index) =>
      index < args.length && args[index] != null ? '${args[index]}' : '';

  static Object? _at(List<dynamic> args, int index) => index < args.length ? args[index] : null;

  static Map<String, dynamic> _decodeMap(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {'value': decoded};
    } catch (_) {
      return const {};
    }
  }

  String _toggleKeyFor(String plugin, String key) {
    final (owner, id) = parseToggleKey(key, defaultOwner: plugin);
    return toggleKey(owner, id);
  }

  PluginTask _ownTask(String plugin, String id) {
    final task = tasks[id];
    if (task == null) {
      throw HostFunctionException(404, 'Task $id not found');
    }
    if (task.owner != plugin) {
      throw HostFunctionException(403, 'Task $id belongs to ${task.owner}');
    }
    return task;
  }

  void _registerKernelApi() {
    const area = 'kernel';
    void host(String name, HostFunction handler, String doc) => registerHost(name, handler, doc: doc, area: area);

    host('plugins.list', (plugin, args) async {
      final all = await engine.plugins();
      return [
        for (final installed in all)
          {
            'name': installed.name,
            'title': installed.title,
            'version': installed.version,
            'description': installed.description,
            'author': installed.author,
            'enabled': installed.enabled,
            'loaded': engine.isLoaded(installed.name),
            'methods': [
              for (final method in installed.methods) {'name': method.name, 'title': method.title, 'types': method.types},
            ],
            'contributes': installed.manifest['contributes'],
          },
      ];
    }, '[] -> [{ name, title, version, enabled, loaded, methods, contributes }]');

    host('plugins.call', (plugin, args) async {
      final target = _text(args, 0);
      final method = _text(args, 1);
      final data = _arg(args, 2);
      final options = _arg(args, 3);
      final timeoutMs = options['timeoutMs'];
      return call(
        target,
        method,
        '${options['type'] ?? PluginCallType.pluginCall}',
        {...data, 'from': plugin},
        config: options['config'] is Map ? Map<String, dynamic>.from(options['config'] as Map) : const {},
        timeout: timeoutMs is num ? Duration(milliseconds: timeoutMs.toInt()) : null,
      );
    }, '[plugin, method, data?, { type?, timeoutMs?, config? }] -> response (data gets "from": caller)');

    host('app.info', (plugin, args) async {
      PackageInfo? info;
      try {
        info = await PackageInfo.fromPlatform();
      } catch (_) {
        info = null;
      }
      final dispatcher = PlatformDispatcher.instance;
      return {
        'name': info?.appName ?? 'Immich',
        'packageName': info?.packageName,
        'version': info?.version,
        'buildNumber': info?.buildNumber,
        'platform': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'locale': dispatcher.locale.toLanguageTag(),
        'brightness': dispatcher.platformBrightness.name,
        'kernelApi': apiVersion,
        'route': currentRoute,
        'plugin': plugin,
      };
    }, '[] -> { name, packageName, version, buildNumber, platform, osVersion, locale, brightness, kernelApi, route }');

    for (final MapEntry(key: type, value: field) in commandFields.entries) {
      host('ui.$type', (plugin, args) {
        final first = _at(args, 0);
        final payload = first is Map
            ? Map<String, dynamic>.from(first)
            : <String, dynamic>{if (field != null && first != null) field: first};
        return command(plugin, {...payload, 'type': type});
      }, '[{ ...command fields }] or [${field ?? ''}] -> command result');
    }

    host('ui.update', (plugin, args) async {
      final second = _arg(args, 1);
      final envelope = second.containsKey('type') ? {'ui': second} : second;
      return {'updated': await command(plugin, {'type': 'uiUpdate', 'surface': _text(args, 0), ...envelope})};
    }, '[surfaceId, tree | { ui?, state? }] -> { updated: count } (kept for 10 s if the surface is not mounted)');
    host('ui.patch', (plugin, args) async {
      return {
        'patched': await command(plugin, {
          'type': 'uiPatch',
          'surface': _text(args, 0),
          'node': _text(args, 1),
          'props': _arg(args, 2),
        }),
      };
    }, '[surfaceId, nodeId, props] -> { patched: count } (null prop values remove the prop)');
    host(
      'ui.setState',
      (plugin, args) async => {'updated': surfaces.setState(plugin, _text(args, 0), _arg(args, 1))},
      '[surfaceId, { inputId: value }] -> { updated: count }',
    );
    host(
      'ui.surfaces',
      (plugin, args) async => surfaces.describe(plugin: plugin),
      '[] -> [{ plugin, surface, hasTree }] mounted surfaces of the caller',
    );
    host('views.setHeight', (plugin, args) async {
      final first = _at(args, 0);
      final options = first is Map ? Map<String, dynamic>.from(first) : {'instance': first, 'height': _at(args, 1)};
      final height = options['height'];
      return views.setHeight('${options['instance']}', height is num ? height.toDouble() : null);
    }, '[instance, heightDp] or [{ instance, height }] -> bool (instance comes in every plugin view\'s params)');

    host('toggles.get', (plugin, args) async {
      final fallback = _at(args, 1);
      return toggles.get(_toggleKeyFor(plugin, _text(args, 0)), defaultValue: fallback is bool ? fallback : null);
    }, '[id | "owner/id", default?] -> bool (ids without owner are the caller\'s)');
    host('toggles.set', (plugin, args) async {
      final key = _toggleKeyFor(plugin, _text(args, 0));
      await toggles.set(key, _at(args, 1) == true, source: plugin);
      return toggles.get(key);
    }, '[id | "owner/id", value] -> bool; emits toggle.changed');
    host(
      'toggles.toggle',
      (plugin, args) async => toggles.toggle(_toggleKeyFor(plugin, _text(args, 0)), source: plugin),
      '[id | "owner/id"] -> new value',
    );
    host('toggles.list', (plugin, args) async => toggles.describe(), '[] -> [{ key, owner, id, value, title? }]');

    host('tasks.start', (plugin, args) async {
      final first = _at(args, 0);
      final options = first is Map ? Map<String, dynamic>.from(first) : _arg(args, 1);
      final progress = options['progress'];
      final task = tasks.start(
        plugin,
        '${first is Map ? options['title'] ?? plugin : first ?? plugin}',
        cancellable: options['cancellable'] == true,
        progress: progress is num ? progress.toDouble() : null,
        message: options['message'] as String?,
      );
      return task.id;
    }, '[title, { cancellable?, progress? (0..1), message? }] -> taskId; cancel arrives as event task.cancelled');
    host('tasks.update', (plugin, args) async {
      final task = _ownTask(plugin, _text(args, 0));
      final options = _arg(args, 1);
      final progress = options['progress'];
      return tasks.update(
        task.id,
        progress: progress is num ? progress.toDouble() : null,
        message: options['message'] as String?,
        title: options['title'] as String?,
        clearProgress: options['indeterminate'] == true || (options.containsKey('progress') && progress == null),
      );
    }, '[taskId, { progress?, message?, title?, indeterminate? }] -> bool (false once finished or cancelled)');
    host('tasks.finish', (plugin, args) async {
      final task = _ownTask(plugin, _text(args, 0));
      final options = _arg(args, 1);
      return tasks.finish(task.id, message: options['message'] as String?, error: options['error'] as String?);
    }, '[taskId, { message?, error? }] -> bool');
    host('tasks.cancel', (plugin, args) async {
      final task = _ownTask(plugin, _text(args, 0));
      return tasks.cancel(task.id);
    }, '[taskId] -> bool');
    host('tasks.get', (plugin, args) async => tasks[_text(args, 0)]?.toJson(), '[taskId] -> task JSON or null');
    host(
      'tasks.isCancelled',
      (plugin, args) async => tasks[_text(args, 0)]?.isCancelled ?? false,
      '[taskId] -> bool (poll from long loops; the task.cancelled event also arrives)',
    );
    host(
      'tasks.list',
      (plugin, args) async => [for (final task in tasks.all) task.toJson()],
      '[] -> [task JSON] (running and recently finished)',
    );

    host(
      'assetData.get',
      (plugin, args) async => assetData.get(plugin, _text(args, 0), _at(args, 1) == null ? null : _text(args, 1)),
      '[assetId, key?] -> value, or the whole map without key',
    );
    host('assetData.set', (plugin, args) async {
      await assetData.set(plugin, _text(args, 0), _text(args, 1), _at(args, 2));
      return true;
    }, '[assetId, key, value] -> true (null deletes); emits assetData.changed');
    host('assetData.delete', (plugin, args) async {
      await assetData.delete(plugin, _text(args, 0), _at(args, 1) == null ? null : _text(args, 1));
      return true;
    }, '[assetId, key?] -> true (without key: everything for the asset)');
    host('assetData.list', (plugin, args) async {
      final assetId = _at(args, 0);
      return assetId == null ? assetData.assets(plugin) : assetData.keys(plugin, '$assetId');
    }, '[assetId?] -> keys of the asset, or asset ids with data');

    host('events.emit', (plugin, args) async {
      final payload = _at(args, 1);
      emit(_text(args, 0), payload is Map ? Map<String, dynamic>.from(payload) : {'value': ?payload}, source: plugin);
      return true;
    }, '[event, payload?] -> true; delivered to every other plugin subscribed to it');

    host('slots.add', (plugin, args) async {
      final item = SlotContribution.fromJson(plugin, _arg(args, 0), index: 100000 + (_runtimeSlots[plugin]?.length ?? 0));
      if (item == null) {
        throw const HostFunctionException(400, 'A slot item needs "slot"');
      }
      final list = _runtimeSlots.putIfAbsent(plugin, () => [])..removeWhere((existing) => existing.id == item.id);
      list.add(item);
      _applyIndex(_plugins);
      return item.toJson();
    }, '[slot item JSON as in contributes.slots] -> item; lives until the plugin is unloaded');
    host('slots.remove', (plugin, args) async {
      final id = _text(args, 0);
      final removed = _runtimeSlots[plugin]?.length ?? 0;
      _runtimeSlots[plugin]?.removeWhere((item) => item.id == id);
      _applyIndex(_plugins);
      return removed != (_runtimeSlots[plugin]?.length ?? 0);
    }, '[id] -> bool');
    host('slots.list', (plugin, args) async {
      return [for (final item in slot(_text(args, 0), context: _arg(args, 1))) item.toJson()];
    }, '[slotId, context?] -> contributions that match');

    host('kernel.slots', (plugin, args) async => catalog('slot'), '[] -> known slots and their contributions');
    host('kernel.hooks', (plugin, args) async => catalog('hook'), '[] -> known hooks and handlers');
    host('kernel.events', (plugin, args) async => catalog('event'), '[] -> known events and subscribers');
    host('kernel.hostFunctions', (plugin, args) async => catalog('host'), '[] -> registered host functions');
    host('kernel.info', (plugin, args) async {
      return {
        'kernelApi': apiVersion,
        'plugins': [for (final plugin in _plugins) plugin.name],
        'tabs': [for (final tab in _tabs) tab.toJson()],
        'settings': [for (final page in _settings) page.toJson()],
        'tools': [for (final tool in _tools) tool.toJson()],
        'theme': themeOverride?.toJson(),
        'toggles': toggles.describe(),
      };
    }, '[] -> { kernelApi, plugins, tabs, settings, tools, theme, toggles }');

    declareEvent('app.start', doc: 'The plugin engine started.', area: area);
    declareEvent('route.changed', doc: 'Navigation changed.', payload: {'route': 'Name', 'previous': 'Name?'});
    declareEvent('toggle.changed', payload: {'key': 'owner/id', 'owner': '', 'id': '', 'value': true, 'source': ''});
    declareEvent('task.started', payload: 'task JSON', area: area);
    declareEvent('task.finished', payload: 'task JSON', area: area);
    declareEvent('task.failed', payload: 'task JSON', area: area);
    declareEvent('task.cancelled', payload: {'id': '', 'plugin': '', 'title': ''}, area: area);
    declareEvent('assetData.changed', payload: {'plugin': '', 'assetId': '', 'key': '', 'value': null}, area: area);
    declareSlot('plugins.page', kinds: ['page', 'tile', 'button'], doc: 'Entries on the Plugins page.', area: area);
    declareSlot('global', kinds: ['overlay'], doc: 'Overlay on every screen.', area: area);
    declareSlot('viewer', kinds: ['overlay'], context: ['asset'], doc: 'Overlay over the viewer.', area: area);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------------------------------------------

  Future<void> _loadState() async {
    try {
      final file = File(p.join((await _root()).path, _stateFile));
      if (!file.existsSync()) {
        return;
      }
      final json = jsonDecode(await file.readAsString());
      final stored = json is Map ? json['toggles'] : null;
      if (stored is Map) {
        toggles.restore({
          for (final MapEntry(:key, :value) in stored.entries)
            if (value is bool) '$key': value,
        });
      }
    } catch (error, stack) {
      _log.warning('Unable to read kernel state', error, stack);
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () => unawaited(_saveState()));
  }

  Future<void> _saveState() async {
    try {
      final file = File(p.join((await _root()).path, _stateFile));
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({
          'toggles': {
            for (final MapEntry(:key, :value) in toggles.all.entries)
              if (toggles.definition(key)?.write == null) key: value,
          },
        }),
        flush: true,
      );
      await temp.rename(file.path);
    } catch (error, stack) {
      _log.warning('Unable to save kernel state', error, stack);
    }
  }

  @override
  void dispose() {
    unawaited(_engineChanges?.cancel());
    _saveTimer?.cancel();
    for (final throttle in _throttles.values) {
      throttle.dispose();
    }
    if (current == this) {
      current = null;
    }
    hooksRevision.dispose();
    unawaited(_hookChanges.close());
    unawaited(_unloaded.close());
    engine
      ..hostLookup = null
      ..eventBus = null
      ..uiHandler = null;
    engine.runtime.emitHandler = null;
    toggles.dispose();
    tasks.dispose();
    super.dispose();
  }
}
