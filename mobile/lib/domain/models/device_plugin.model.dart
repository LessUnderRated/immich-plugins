import 'package:immich_mobile/domain/plugins/plugin_hook_runner.dart';
import 'package:immich_mobile/domain/plugins/plugin_ids.dart';

List<String> _strings(Object? value) => value is List ? value.whereType<String>().toList() : const [];

Map<String, dynamic> _map(Object? value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

Map<String, dynamic>? _mapOrNull(Object? value) => value is Map ? Map<String, dynamic>.from(value) : null;

List<Map> _maps(Object? value) => value is List ? value.whereType<Map>().toList() : const [];

String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;

int? _int(Object? value) => value is num ? value.toInt() : (value is String ? int.tryParse(value) : null);

double? _double(Object? value) => value is num ? value.toDouble() : (value is String ? double.tryParse(value) : null);

Map<String, double> _position(Object? value) => value is Map
    ? {
        for (final MapEntry(:key, :value) in value.entries)
          if (value is num) '$key': value.toDouble(),
      }
    : const {};

class DevicePluginMethod {
  final String name;
  final String title;
  final String description;
  final List<String> types;
  final bool hostFunctions;
  final List<String> allowedHosts;
  final List<String> uiHints;
  final Map<String, dynamic> schema;
  final bool pixels;

  const DevicePluginMethod({
    required this.name,
    required this.title,
    required this.description,
    required this.types,
    required this.hostFunctions,
    required this.allowedHosts,
    required this.uiHints,
    required this.schema,
    this.pixels = false,
  });

  factory DevicePluginMethod.fromJson(Map<String, dynamic> json) => DevicePluginMethod(
    name: json['name'] as String,
    title: json['title'] as String? ?? json['name'] as String,
    description: json['description'] as String? ?? '',
    types: _strings(json['types']),
    hostFunctions: json['hostFunctions'] == true,
    allowedHosts: _strings(json['allowedHosts']),
    uiHints: _strings(json['uiHints']),
    schema: _map(json['schema']),
    pixels: json['pixels'] == true,
  );

  bool get isFilter => uiHints.contains('Filter');

  bool get isGalleryView => uiHints.contains('GalleryView') || types.contains('GalleryViewV1');

  bool get isCensorStyle => uiHints.contains('CensorStyle') || types.contains('CensorStyleV1');

  bool get isAssetAction => uiHints.contains('AssetAction') || types.contains('AssetActionV1');

  bool get isViewerFilter => uiHints.contains('ViewerFilter') || types.contains('ViewerFilterV1');
}

enum PluginContributionKind { button, page, overlay }

class PluginContribution {
  final String plugin;
  final PluginContributionKind kind;
  final String id;
  final String title;
  final String slot;
  final String? icon;
  final String? method;
  final String? view;
  final bool interactive;
  final Map<String, dynamic> params;

  const PluginContribution({
    required this.plugin,
    required this.kind,
    required this.id,
    required this.title,
    required this.slot,
    this.icon,
    this.method,
    this.view,
    this.interactive = false,
    this.params = const {},
  });

  String get key => '$plugin#${kind.name}#$id';

  static List<PluginContribution> parse(String plugin, Object? contributes) {
    if (contributes is! Map) {
      return const [];
    }
    PluginContribution item(PluginContributionKind kind, Map json, String defaultSlot) => PluginContribution(
      plugin: plugin,
      kind: kind,
      id: '${json['id'] ?? json['method'] ?? json['view'] ?? kind.name}',
      title: '${json['title'] ?? json['id'] ?? plugin}',
      slot: '${json['slot'] ?? defaultSlot}',
      icon: json['icon'] as String?,
      method: json['method'] as String?,
      view: json['view'] as String?,
      interactive: json['interactive'] == true,
      params: json['params'] is Map ? Map<String, dynamic>.from(json['params'] as Map) : const {},
    );
    List<Map> list(Object? value) => value is List ? value.whereType<Map>().toList() : const [];
    return [
      for (final json in list(contributes['buttons'])) item(PluginContributionKind.button, json, 'viewer.topBar'),
      for (final json in list(contributes['pages'])) item(PluginContributionKind.page, json, 'plugins.page'),
      for (final json in list(contributes['overlays'])) item(PluginContributionKind.overlay, json, 'viewer'),
    ];
  }
}

class DevicePlugin {
  final String name;
  final String version;
  final String title;
  final String description;
  final String author;
  final String codePath;
  final String? entry;
  final List<DevicePluginMethod> methods;
  final List<Map<String, dynamic>> templates;
  final List<PluginContribution> contributions;
  final Map<String, String> events;
  final Map<String, Map<String, dynamic>> routes;
  final bool enabled;
  final bool bundled;

  /// Manifest v2 (`contributes.*`). Legacy `buttons`, `pages` and `overlays` also appear in [slots].
  final List<SlotContribution> slots;
  final Map<String, BuiltinRules> builtins;
  final List<PluginHookHandler> hooks;
  final Map<String, int> eventThrottleMs;
  final List<ToolContribution> tools;
  final List<TabContribution> tabs;
  final List<SettingsContribution> settings;
  final ThemeOverride? theme;
  final Map<String, Map<String, String>> strings;

  /// The raw manifest, for introspection (`plugins.list`).
  final Map<String, dynamic> manifest;

  const DevicePlugin({
    required this.name,
    required this.version,
    required this.title,
    required this.description,
    required this.author,
    required this.codePath,
    this.entry,
    required this.methods,
    required this.templates,
    this.contributions = const [],
    this.events = const {},
    this.routes = const {},
    required this.enabled,
    required this.bundled,
    this.slots = const [],
    this.builtins = const {},
    this.hooks = const [],
    this.eventThrottleMs = const {},
    this.tools = const [],
    this.tabs = const [],
    this.settings = const [],
    this.theme,
    this.strings = const {},
    this.manifest = const {},
  });

  factory DevicePlugin.fromManifest(
    Map<String, dynamic> json, {
    required String codePath,
    required bool enabled,
    required bool bundled,
  }) {
    final name = json['name'] as String;
    final contributes = _map(json['contributes']);
    return DevicePlugin(
      manifest: json,
      slots: SlotContribution.parseAll(name, contributes),
      builtins: BuiltinRules.parseAll(contributes['builtins']),
      hooks: parseHookHandlers(name, contributes['hooks']),
      eventThrottleMs: {
        for (final MapEntry(:key, :value) in _map(contributes['events']).entries)
          if (value is Map && _int(value['throttleMs']) != null) key: _int(value['throttleMs'])!,
      },
      tools: [
        for (final (index, tool) in _maps(contributes['tools']).indexed)
          ToolContribution.fromJson(name, Map<String, dynamic>.from(tool), index: index),
      ],
      tabs: [
        for (final (index, tab) in _maps(contributes['tabs']).indexed)
          TabContribution.fromJson(name, Map<String, dynamic>.from(tab), index: index),
      ],
      settings: [
        if (contributes['settings'] is Map)
          SettingsContribution.fromJson(name, _map(contributes['settings']), index: 0)
        else
          for (final (index, page) in _maps(contributes['settings']).indexed)
            SettingsContribution.fromJson(name, Map<String, dynamic>.from(page), index: index),
      ],
      theme: contributes['theme'] is Map ? ThemeOverride.fromJson(_map(contributes['theme'])) : null,
      strings: {
        for (final MapEntry(:key, :value) in _map(contributes['strings']).entries)
          if (value is Map) key: {for (final entry in value.entries) '${entry.key}': '${entry.value}'},
      },
      name: name,
      version: json['version'] as String? ?? '0.0.0',
      title: json['title'] as String? ?? json['name'] as String,
      description: json['description'] as String? ?? '',
      author: json['author'] as String? ?? '',
      codePath: codePath,
      entry: json['entry'] as String?,
      methods: (json['methods'] as List? ?? const [])
          .whereType<Map>()
          .map((method) => DevicePluginMethod.fromJson(Map<String, dynamic>.from(method)))
          .toList(),
      templates: (json['templates'] as List? ?? const []).whereType<Map>().map(Map<String, dynamic>.from).toList(),
      contributions: PluginContribution.parse(name, json['contributes']),
      events: json['contributes'] is Map && (json['contributes'] as Map)['events'] is Map
          ? {
              for (final MapEntry(:key, :value) in ((json['contributes'] as Map)['events'] as Map).entries)
                if (value is! Map)
                  '$key': '$value'
                else if (value['method'] != null)
                  '$key': '${value['method']}',
            }
          : const {},
      routes: json['contributes'] is Map && (json['contributes'] as Map)['routes'] is Map
          ? {
              for (final MapEntry(:key, :value) in ((json['contributes'] as Map)['routes'] as Map).entries)
                if (value is Map) '$key': Map<String, dynamic>.from(value),
            }
          : const {},
      enabled: enabled,
      bundled: bundled,
    );
  }

  bool get usesHostFunctions => methods.any((method) => method.hostFunctions);

  DevicePluginMethod? method(String name) {
    for (final method in methods) {
      if (method.name == name) {
        return method;
      }
    }
    return null;
  }
}

class DeviceWorkflowStep {
  final String id;
  final String pluginName;
  final String methodName;
  final Map<String, dynamic> config;
  final bool enabled;

  const DeviceWorkflowStep({
    required this.id,
    required this.pluginName,
    required this.methodName,
    required this.config,
    this.enabled = true,
  });

  factory DeviceWorkflowStep.fromJson(Map<String, dynamic> json) => DeviceWorkflowStep(
    id: json['id'] as String,
    pluginName: json['pluginName'] as String,
    methodName: json['methodName'] as String,
    config: _map(json['config']),
    enabled: json['enabled'] != false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'pluginName': pluginName,
    'methodName': methodName,
    'config': config,
    'enabled': enabled,
  };

  DeviceWorkflowStep copyWith({Map<String, dynamic>? config, bool? enabled}) => DeviceWorkflowStep(
    id: id,
    pluginName: pluginName,
    methodName: methodName,
    config: config ?? this.config,
    enabled: enabled ?? this.enabled,
  );
}

class DeviceWorkflow {
  final String id;
  final String name;
  final String trigger;
  final bool enabled;
  final List<DeviceWorkflowStep> steps;

  const DeviceWorkflow({
    required this.id,
    required this.name,
    required this.trigger,
    required this.enabled,
    required this.steps,
  });

  factory DeviceWorkflow.fromJson(Map<String, dynamic> json) => DeviceWorkflow(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Workflow',
    trigger: json['trigger'] as String? ?? deviceAssetCreateTrigger,
    enabled: json['enabled'] != false,
    steps: (json['steps'] as List? ?? const [])
        .whereType<Map>()
        .map((step) => DeviceWorkflowStep.fromJson(Map<String, dynamic>.from(step)))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'trigger': trigger,
    'enabled': enabled,
    'steps': steps.map((step) => step.toJson()).toList(),
  };

  DeviceWorkflow copyWith({String? name, bool? enabled, List<DeviceWorkflowStep>? steps}) => DeviceWorkflow(
    id: id,
    name: name ?? this.name,
    trigger: trigger,
    enabled: enabled ?? this.enabled,
    steps: steps ?? this.steps,
  );
}

const deviceAssetCreateTrigger = 'AssetCreate';
const deviceAssetType = 'AssetV1';

/// Order of the built-in item at [index] (0-based) when plugin items are merged into a built-in list: 100, 200, ...
/// A plugin item with `"order": 150` lands between the first and second built-in item.
int builtinItemOrder(int index) => (index + 1) * 100;

/// One item a plugin adds to a slot (`contributes.slots`, or a legacy `buttons` / `pages` / `overlays` entry).
class SlotContribution {
  /// Order of plugin items that do not set one: after every built-in item.
  static const defaultOrder = 10000;

  final String plugin;
  final String id;
  final String slot;
  final PluginSlotKind kind;
  final String title;
  final String? subtitle;
  final String? tooltip;
  final String? icon;

  /// Called with `SlotV1` (or `ButtonV1` for legacy items) when the item is tapped.
  final String? method;

  /// Called with `SlotV1` to get `{ "ui": tree }` content; cached per context until `refresh` / `refreshSlots`.
  final String? uiMethod;

  /// Static JSON UI content.
  final Map<String, dynamic>? ui;

  /// Native view type (`ImmichViewPlugin.createView`).
  final String? view;

  /// `"hybrid"` selects Hybrid Composition for [view]; default is the texture layer.
  final String? composition;

  /// Height for content items (`section`, `panel`, `view`) that need one (native views do).
  final double? height;
  final Map<String, dynamic> params;
  final int order;
  final Object? when;
  final bool interactive;

  /// Overlay / badge placement: `left`, `top`, `right`, `bottom`, `width`, `height`.
  final Map<String, double> position;

  /// Badge / overlay alignment: `topLeft`, `topRight`, `bottomLeft`, `bottomRight`, `center`, ...
  final String? alignment;
  final bool destructive;

  /// `toggle` items: icon and title while on, and the value before the user first changes it.
  final String? activeIcon;
  final String? activeTitle;
  final bool defaultValue;

  /// JSON UI surface id of this item's content (target of `ui.update` / `ui.patch`); default `slot:<slot>/<id>`.
  final String? surface;

  /// `ButtonV1` for items converted from legacy `buttons` / `pages` / `overlays`: they are called exactly as before.
  final String? legacyType;

  /// Declaration index inside the plugin's manifest (stable sort key).
  final int index;

  const SlotContribution({
    required this.plugin,
    required this.id,
    required this.slot,
    required this.kind,
    required this.title,
    this.subtitle,
    this.tooltip,
    this.icon,
    this.method,
    this.uiMethod,
    this.ui,
    this.view,
    this.composition,
    this.height,
    this.params = const {},
    this.order = defaultOrder,
    this.when,
    this.interactive = false,
    this.position = const {},
    this.alignment,
    this.destructive = false,
    this.activeIcon,
    this.activeTitle,
    this.defaultValue = false,
    this.surface,
    this.legacyType,
    this.index = 0,
  });

  bool get isLegacy => legacyType != null;

  bool get isToggle => kind == PluginSlotKind.toggle;

  /// Key of a `toggle` item's state in the kernel's toggle store: `<plugin>/<id>`.
  String get toggleKey => '$plugin/$id';

  /// The JSON UI surface id of this item's content.
  String get surfaceId => surface ?? 'slot:$slot/$id';

  /// Unique key across all plugins and slots.
  String get key => '$plugin#$slot#$id';

  /// The id used in built-in rules (`order`, `hide`): `plugin:<plugin>/<id>`.
  String get itemId => pluginItemId(plugin, id);

  bool get hasContent => ui != null || uiMethod != null || view != null;

  bool get isActionable => method != null || (view != null && PluginSlotKindGroups.actionable.contains(kind));

  static SlotContribution? fromJson(
    String plugin,
    Map json, {
    int index = 0,
    PluginSlotKind? kind,
    String? defaultSlot,
    String? legacyType,
  }) {
    final slot = _string(json['slot']) ?? defaultSlot;
    if (slot == null) {
      return null;
    }
    final resolvedKind =
        kind ??
        PluginSlotKind.parse(json['kind']) ??
        (json['view'] != null
            ? PluginSlotKind.view
            : (json['ui'] != null || json['uiMethod'] != null ? PluginSlotKind.section : PluginSlotKind.button));
    final id = '${json['id'] ?? json['method'] ?? json['uiMethod'] ?? json['view'] ?? (legacyType != null ? resolvedKind.name : 'item$index')}';
    return SlotContribution(
      plugin: plugin,
      id: id,
      slot: slot,
      kind: resolvedKind,
      title: '${json['title'] ?? json['id'] ?? plugin}',
      subtitle: _string(json['subtitle']),
      tooltip: _string(json['tooltip']),
      icon: _string(json['icon']),
      method: _string(json['method']),
      uiMethod: _string(json['uiMethod']),
      ui: _mapOrNull(json['ui']),
      view: _string(json['view']),
      composition: _string(json['composition']),
      height: _double(json['height']),
      params: json['params'] is Map ? Map<String, dynamic>.from(json['params'] as Map) : const {},
      order: _int(json['order']) ?? defaultOrder,
      when: json['when'],
      interactive: json['interactive'] == true,
      position: _position(json['position']),
      alignment: _string(json['alignment']),
      destructive: json['destructive'] == true,
      activeIcon: _string(json['activeIcon']),
      activeTitle: _string(json['activeTitle']),
      defaultValue: (json['default'] ?? json['value']) == true,
      surface: _string(json['surface']),
      legacyType: legacyType,
      index: index,
    );
  }

  /// Legacy `buttons`, `pages` and `overlays` (in that order) followed by `slots`.
  static List<SlotContribution> parseAll(String plugin, Map<String, dynamic> contributes) {
    var index = 0;
    SlotContribution? legacy(Map json, PluginSlotKind kind, String slot) =>
        fromJson(plugin, json, index: index++, kind: kind, defaultSlot: slot, legacyType: PluginCallType.button);
    return [
      for (final json in _maps(contributes['buttons'])) ?legacy(json, PluginSlotKind.button, 'viewer.topBar'),
      for (final json in _maps(contributes['pages'])) ?legacy(json, PluginSlotKind.page, 'plugins.page'),
      for (final json in _maps(contributes['overlays'])) ?legacy(json, PluginSlotKind.overlay, 'viewer'),
      for (final json in _maps(contributes['slots'])) ?fromJson(plugin, json, index: index++),
    ];
  }

  Map<String, dynamic> toJson() => {
    'plugin': plugin,
    'id': id,
    'slot': slot,
    'kind': kind.name,
    'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    if (icon != null) 'icon': icon,
    if (method != null) 'method': method,
    if (uiMethod != null) 'uiMethod': uiMethod,
    if (ui != null) 'ui': ui,
    if (view != null) 'view': view,
    if (composition != null) 'composition': composition,
    if (height != null) 'height': height,
    'order': order,
    if (when != null) 'when': when,
    if (kind == PluginSlotKind.toggle) 'default': defaultValue,
    if (activeIcon != null) 'activeIcon': activeIcon,
    if (legacyType != null) 'legacy': true,
  };
}

/// One entry of a slot after merging built-in items with plugin items (see [BuiltinRules.arrange]).
sealed class PluginSlotEntry<T> {
  const PluginSlotEntry();

  /// Built-in id, or `plugin:<plugin>/<id>` for plugin items.
  String get id;
}

class BuiltinSlotEntry<T> extends PluginSlotEntry<T> {
  final T item;
  @override
  final String id;

  /// Label from a `rename` rule, if any.
  final String? label;

  /// Icon name from an `icons` rule, if any.
  final String? icon;

  const BuiltinSlotEntry(this.item, this.id, {this.label, this.icon});
}

class ContributedSlotEntry<T> extends PluginSlotEntry<T> {
  final SlotContribution contribution;

  const ContributedSlotEntry(this.contribution);

  @override
  String get id => contribution.itemId;
}

/// `contributes.builtins.<slot>`: hide, reorder, rename and re-icon the built-in items of a slot.
///
/// `order` lists ids (built-in ids or `plugin:<plugin>/<id>`) that move to the front in that order; a `"..."` (or
/// `"*"`) entry splits the list: ids after it move to the end. Ids not listed keep their position (built-ins in their original
/// order, plugin items by their `order` number). Rules from several plugins merge: `hide` is the union, `order` lists
/// are concatenated in plugin order, `rename` / `icons` take the last plugin's value per id.
class BuiltinRules {
  static const rest = '...';

  /// Alternative spelling of [rest].
  static const restAlt = '*';

  static bool _isRest(String id) => id == rest || id == restAlt;
  static const empty = BuiltinRules();

  final Set<String> hide;
  final List<String> order;
  final Map<String, String> rename;
  final Map<String, String> icons;

  const BuiltinRules({this.hide = const {}, this.order = const [], this.rename = const {}, this.icons = const {}});

  factory BuiltinRules.fromJson(Map json) => BuiltinRules(
    hide: _strings(json['hide']).toSet(),
    order: _strings(json['order']),
    rename: {for (final MapEntry(:key, :value) in _map(json['rename']).entries) key: '$value'},
    icons: {for (final MapEntry(:key, :value) in _map(json['icons']).entries) key: '$value'},
  );

  static Map<String, BuiltinRules> parseAll(Object? json) => {
    for (final MapEntry(:key, :value) in _map(json).entries)
      if (value is Map) key: BuiltinRules.fromJson(value),
  };

  bool get isEmpty => hide.isEmpty && order.isEmpty && rename.isEmpty && icons.isEmpty;

  BuiltinRules merge(BuiltinRules other) {
    if (isEmpty) {
      return other;
    }
    if (other.isEmpty) {
      return this;
    }
    return BuiltinRules(
      hide: {...hide, ...other.hide},
      order: [...order, ...other.order.where((id) => _isRest(id) || !order.contains(id))],
      rename: {...rename, ...other.rename},
      icons: {...icons, ...other.icons},
    );
  }

  bool hides(String id) => hide.contains(id);

  /// The renamed label for a built-in id, or [fallback].
  String? label(String id, [String? fallback]) => rename[id] ?? fallback;

  String? icon(String id, [String? fallback]) => icons[id] ?? fallback;

  /// Hides and reorders a list of built-in items.
  List<T> apply<T>(List<T> items, String Function(T item) id) => [
    for (final entry in arrange<T>(items, id))
      if (entry is BuiltinSlotEntry<T>) entry.item,
  ];

  /// Merges built-in items with plugin items into one ordered list, applying these rules.
  List<PluginSlotEntry<T>> arrange<T>(
    List<T> builtins,
    String Function(T item) id, [
    List<SlotContribution> contributions = const [],
  ]) {
    final entries = <(int order, int group, int seq, PluginSlotEntry<T> entry)>[];
    for (final (index, item) in builtins.indexed) {
      final itemId = id(item);
      if (hides(itemId)) {
        continue;
      }
      entries.add((
        builtinItemOrder(index),
        0,
        index,
        BuiltinSlotEntry<T>(item, itemId, label: rename[itemId], icon: icons[itemId]),
      ));
    }
    for (final (index, contribution) in contributions.indexed) {
      if (hides(contribution.itemId)) {
        continue;
      }
      entries.add((contribution.order, 1, index, ContributedSlotEntry<T>(contribution)));
    }
    entries.sort((a, b) {
      final byOrder = a.$1.compareTo(b.$1);
      if (byOrder != 0) {
        return byOrder;
      }
      final byGroup = a.$2.compareTo(b.$2);
      return byGroup != 0 ? byGroup : a.$3.compareTo(b.$3);
    });
    final sorted = [for (final entry in entries) entry.$4];
    if (order.isEmpty) {
      return sorted;
    }

    final split = order.indexWhere(_isRest);
    final head = split == -1 ? order : order.sublist(0, split);
    final tail = split == -1 ? const <String>[] : order.sublist(split + 1);
    final byId = {for (final entry in sorted) entry.id: entry};
    final placed = <String>{};
    List<PluginSlotEntry<T>> pick(List<String> ids) => [
      for (final itemId in ids)
        if (byId[itemId] != null && placed.add(itemId)) byId[itemId]!,
    ];
    final first = pick(head);
    final last = pick(tail);
    return [
      ...first,
      for (final entry in sorted)
        if (!placed.contains(entry.id)) entry,
      ...last,
    ];
  }

  Map<String, dynamic> toJson() => {
    if (hide.isNotEmpty) 'hide': hide.toList(),
    if (order.isNotEmpty) 'order': order,
    if (rename.isNotEmpty) 'rename': rename,
    if (icons.isNotEmpty) 'icons': icons,
  };
}

/// Parses `contributes.hooks`: `{ "<hook>": { "before"?: m, "instead"?: m, "after"?: m, "priority"?, "timeoutMs"? } }`
/// (or a list of such objects per hook).
List<PluginHookHandler> parseHookHandlers(String plugin, Object? json) {
  final bindings = <PluginHookHandler>[];
  for (final MapEntry(:key, :value) in _map(json).entries) {
    final specs = value is List ? value.whereType<Map>() : (value is Map ? [value] : const <Map>[]);
    for (final spec in specs) {
      final priority = _int(spec['priority']) ?? 0;
      final timeoutMs = _int(spec['timeoutMs']);
      for (final phase in HookPhase.values) {
        final method = _string(spec[phase.name]);
        if (method != null) {
          bindings.add(
            PluginHookHandler(
              plugin: plugin,
              hook: key,
              phase: phase,
              method: method,
              priority: priority,
              timeout: timeoutMs == null || timeoutMs <= 0 ? null : Duration(milliseconds: timeoutMs),
            ),
          );
        }
      }
    }
  }
  return bindings;
}

/// `contributes.tools`: a tool in a tool surface such as the editor (`editor.image`, `editor.video`).
class ToolContribution {
  final String plugin;
  final String id;
  final String surface;
  final String title;
  final String? subtitle;
  final String? icon;

  /// Called with `EditorToolV1` (editor surfaces) or `SlotV1` (others).
  final String? method;
  final String? uiMethod;
  final Map<String, dynamic> params;
  final int order;
  final Object? when;
  final int index;

  const ToolContribution({
    required this.plugin,
    required this.id,
    required this.surface,
    required this.title,
    this.subtitle,
    this.icon,
    this.method,
    this.uiMethod,
    this.params = const {},
    this.order = SlotContribution.defaultOrder,
    this.when,
    this.index = 0,
  });

  factory ToolContribution.fromJson(String plugin, Map<String, dynamic> json, {int index = 0}) => ToolContribution(
    plugin: plugin,
    id: '${json['id'] ?? json['method'] ?? 'tool$index'}',
    surface: _string(json['surface']) ?? 'editor.image',
    title: '${json['title'] ?? json['id'] ?? plugin}',
    subtitle: _string(json['subtitle']),
    icon: _string(json['icon']),
    method: _string(json['method']),
    uiMethod: _string(json['uiMethod']),
    params: _map(json['params']),
    order: _int(json['order']) ?? SlotContribution.defaultOrder,
    when: json['when'],
    index: index,
  );

  String get itemId => pluginItemId(plugin, id);

  Map<String, dynamic> toJson() => {
    'plugin': plugin,
    'id': id,
    'surface': surface,
    'title': title,
    if (icon != null) 'icon': icon,
    if (method != null) 'method': method,
    if (uiMethod != null) 'uiMethod': uiMethod,
    'order': order,
  };
}

/// `contributes.tabs`: a bottom navigation tab with JSON UI (`uiMethod`, `PageV1`) or a native `view`.
class TabContribution {
  final String plugin;
  final String id;
  final String title;
  final String? icon;
  final String? selectedIcon;
  final String? uiMethod;
  final String? view;
  final String? composition;
  final Map<String, dynamic> params;
  final int order;
  final int index;

  const TabContribution({
    required this.plugin,
    required this.id,
    required this.title,
    this.icon,
    this.selectedIcon,
    this.uiMethod,
    this.view,
    this.composition,
    this.params = const {},
    this.order = SlotContribution.defaultOrder,
    this.index = 0,
  });

  factory TabContribution.fromJson(String plugin, Map<String, dynamic> json, {int index = 0}) => TabContribution(
    plugin: plugin,
    id: '${json['id'] ?? json['uiMethod'] ?? json['view'] ?? 'tab$index'}',
    title: '${json['title'] ?? json['id'] ?? plugin}',
    icon: _string(json['icon']),
    selectedIcon: _string(json['selectedIcon']),
    uiMethod: _string(json['uiMethod']),
    view: _string(json['view']),
    composition: _string(json['composition']),
    params: _map(json['params']),
    order: _int(json['order']) ?? SlotContribution.defaultOrder,
    index: index,
  );

  String get itemId => pluginItemId(plugin, id);

  Map<String, dynamic> toJson() => {
    'plugin': plugin,
    'id': id,
    'title': title,
    if (icon != null) 'icon': icon,
    if (uiMethod != null) 'uiMethod': uiMethod,
    if (view != null) 'view': view,
    'order': order,
  };
}

/// `contributes.settings`: a plugin settings page (JSON UI through `uiMethod` / `PageV1`, or a native `view`).
class SettingsContribution {
  final String plugin;
  final String id;
  final String title;
  final String? subtitle;
  final String? icon;
  final String? uiMethod;
  final String? view;
  final String? composition;
  final Map<String, dynamic> params;
  final int index;

  const SettingsContribution({
    required this.plugin,
    required this.id,
    required this.title,
    this.subtitle,
    this.icon,
    this.uiMethod,
    this.view,
    this.composition,
    this.params = const {},
    this.index = 0,
  });

  factory SettingsContribution.fromJson(String plugin, Map<String, dynamic> json, {int index = 0}) =>
      SettingsContribution(
        plugin: plugin,
        id: '${json['id'] ?? (index == 0 ? 'settings' : 'settings$index')}',
        title: '${json['title'] ?? plugin}',
        subtitle: _string(json['subtitle']),
        icon: _string(json['icon']),
        uiMethod: _string(json['uiMethod']),
        view: _string(json['view']),
        composition: _string(json['composition']),
        params: _map(json['params']),
        index: index,
      );

  Map<String, dynamic> toJson() => {
    'plugin': plugin,
    'id': id,
    'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    if (icon != null) 'icon': icon,
    if (uiMethod != null) 'uiMethod': uiMethod,
    if (view != null) 'view': view,
  };
}

/// Parses `#AARRGGBB`, `#RRGGBB`, `0xAARRGGBB` or an int into an ARGB int.
int? parsePluginColor(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is! String) {
    return null;
  }
  var text = value.trim();
  if (text.startsWith('#')) {
    text = text.substring(1);
  } else if (text.toLowerCase().startsWith('0x')) {
    text = text.substring(2);
  } else {
    return null;
  }
  if (text.length == 3) {
    text = text.split('').map((c) => '$c$c').join();
  }
  if (text.length == 6) {
    text = 'FF$text';
  }
  return text.length == 8 ? int.tryParse(text, radix: 16) : null;
}

/// `contributes.theme` (and the `setTheme` command): seed color, per-brightness color scheme tokens and font.
/// Token names are `ColorScheme` field names (`primary`, `onPrimary`, `surface`, `surfaceContainerHigh`, ...).
class ThemeOverride {
  final int? seedColor;
  final Map<String, int> light;
  final Map<String, int> dark;
  final String? fontFamily;

  /// `light`, `dark` or `system`.
  final String? mode;

  const ThemeOverride({this.seedColor, this.light = const {}, this.dark = const {}, this.fontFamily, this.mode});

  static Map<String, int> _colors(Object? json) => {
    for (final MapEntry(:key, :value) in _map(json).entries)
      if (parsePluginColor(value) != null) key: parsePluginColor(value)!,
  };

  factory ThemeOverride.fromJson(Map<String, dynamic> json) => ThemeOverride(
    seedColor: parsePluginColor(json['seedColor']),
    light: _colors(json['light']),
    dark: _colors(json['dark']),
    fontFamily: _string(json['fontFamily']),
    mode: _string(json['mode']),
  );

  bool get isEmpty => seedColor == null && light.isEmpty && dark.isEmpty && fontFamily == null && mode == null;

  /// [other] wins per key.
  ThemeOverride merge(ThemeOverride? other) => other == null
      ? this
      : ThemeOverride(
          seedColor: other.seedColor ?? seedColor,
          light: {...light, ...other.light},
          dark: {...dark, ...other.dark},
          fontFamily: other.fontFamily ?? fontFamily,
          mode: other.mode ?? mode,
        );

  static String _hex(int color) => '#${color.toRadixString(16).padLeft(8, '0').toUpperCase()}';

  Map<String, dynamic> toJson() => {
    if (seedColor != null) 'seedColor': _hex(seedColor!),
    if (light.isNotEmpty) 'light': light.map((key, value) => MapEntry(key, _hex(value))),
    if (dark.isNotEmpty) 'dark': dark.map((key, value) => MapEntry(key, _hex(value))),
    if (fontFamily != null) 'fontFamily': fontFamily,
    if (mode != null) 'mode': mode,
  };
}
