/// Plugin id conventions, call type names and `when` condition matching.
///
/// Pure Dart: no Flutter imports, so it can be used from services, tests and isolates.
library;

/// `type` values sent to plugin methods (`{ "type", "config", "workflow", "data" }`).
abstract final class PluginCallType {
  /// Workflow step for a new photo (v1).
  static const asset = 'AssetV1';

  /// Legacy `contributes.buttons` item tapped (v1).
  static const button = 'ButtonV1';

  /// Event delivered to a `contributes.events` subscription.
  static const event = 'EventV1';

  /// Selection action (`types: ["AssetActionV1"]`).
  static const assetAction = 'AssetActionV1';

  /// Mosaic brush style.
  static const censorStyle = 'CensorStyleV1';

  /// Censor while viewing.
  static const viewerFilter = 'ViewerFilterV1';

  /// Gallery sort / filter.
  static const galleryView = 'GalleryViewV1';

  /// Slot item tapped, or `uiMethod` content requested.
  static const slot = 'SlotV1';

  /// Hook phase (`before`, `instead`, `after`).
  static const hook = 'HookV1';

  /// JSON UI interaction.
  static const uiEvent = 'UiEventV1';

  /// JSON UI page, tab or settings page opened.
  static const page = 'PageV1';

  /// Editor tool (`panel`, `preview`, `apply`).
  static const editorTool = 'EditorToolV1';

  /// One plugin calling another through the `plugins.call` host function.
  static const pluginCall = 'PluginCallV1';

  static const all = [
    asset,
    button,
    event,
    assetAction,
    censorStyle,
    viewerFilter,
    galleryView,
    slot,
    hook,
    uiEvent,
    page,
    editorTool,
    pluginCall,
  ];
}

/// Phases of a hook, in the order they run.
enum HookPhase {
  before,
  instead,
  after;

  static HookPhase? parse(Object? value) => switch (value) {
    'before' => HookPhase.before,
    'instead' => HookPhase.instead,
    'after' => HookPhase.after,
    _ => null,
  };
}

/// How a slot contribution is presented. The app's call site decides the presentation of a slot; `kind` says which
/// presentations an item fits (see [PluginSlotKindGroups]).
enum PluginSlotKind {
  button,
  menuItem,
  tile,
  section,
  chip,
  badge,
  panel,
  tab,
  view,
  overlay,
  page,
  replace,
  wrap,

  /// On/off icon whose state the app persists per plugin and id (`toggles.get` / `toggles.set`, `toggle.changed`).
  toggle;

  static PluginSlotKind? parse(Object? value) {
    if (value is! String) {
      return null;
    }
    for (final kind in PluginSlotKind.values) {
      if (kind.name == value) {
        return kind;
      }
    }
    return switch (value) {
      'menu' || 'menuitem' || 'menu_item' => PluginSlotKind.menuItem,
      'listTile' || 'item' => PluginSlotKind.tile,
      'nativeView' => PluginSlotKind.view,
      'switch' || 'checkbox' => PluginSlotKind.toggle,
      _ => null,
    };
  }
}

/// Groups of [PluginSlotKind] that one presentation renders.
abstract final class PluginSlotKindGroups {
  /// Items with a title, an icon and a tap action: rendered by button rows, menus, tile lists and chip rows.
  static const actionable = {
    PluginSlotKind.button,
    PluginSlotKind.menuItem,
    PluginSlotKind.tile,
    PluginSlotKind.chip,
    PluginSlotKind.page,
    PluginSlotKind.tab,
    PluginSlotKind.toggle,
  };

  /// Items that render a block of UI (JSON UI or a native view).
  static const content = {PluginSlotKind.section, PluginSlotKind.panel, PluginSlotKind.view};

  /// Items drawn over or instead of a built-in widget.
  static const decoration = {PluginSlotKind.badge, PluginSlotKind.wrap, PluginSlotKind.replace, PluginSlotKind.overlay};
}

/// Special `when` keys the kernel fills in from the slot context.
abstract final class PluginContextKeys {
  static const route = 'route';
  static const assetType = 'assetType';
  static const isVideo = 'isVideo';
  static const isImage = 'isImage';
  static const isLocal = 'isLocal';
  static const isRemote = 'isRemote';
  static const isFavorite = 'isFavorite';
  static const selectionCount = 'selectionCount';
  static const platform = 'platform';
  static const asset = 'asset';
  static const assets = 'assets';

  static const all = [route, assetType, isVideo, isImage, isLocal, isRemote, isFavorite, selectionCount, platform];

  /// Fills the special keys derived from AssetV1 JSON (`context.asset` or the first of `context.assets`) unless the
  /// context already sets them.
  static Map<String, dynamic> derive(Map<String, dynamic> context) {
    final assets = context[PluginContextKeys.assets];
    final asset = context[PluginContextKeys.asset] ?? (assets is List && assets.isNotEmpty ? assets.first : null);
    final derived = <String, dynamic>{};
    if (asset is Map) {
      final type = asset['type'];
      derived[assetType] = type;
      derived[isVideo] = type == 'VIDEO';
      derived[isImage] = type == 'IMAGE';
      derived[isLocal] = asset['isLocal'] ?? asset['localId'] != null;
      derived[isRemote] = asset['isRemote'] ?? asset['remoteId'] != null;
      derived[isFavorite] = asset['isFavorite'] == true;
    }
    if (assets is List) {
      derived[selectionCount] = assets.length;
    }
    return {...derived, ...context};
  }
}

/// Generic slot suffixes every page gets (plan section 4): `<page>.appBar.actions`, `<page>.appBar.menu`, ...
abstract final class PluginSlotSuffix {
  static const appBarActions = '.appBar.actions';
  static const appBarMenu = '.appBar.menu';
  static const header = '.header';
  static const footer = '.footer';
  static const empty = '.empty';
  static const fab = '.fab';
  static const body = '.body';

  static const all = [appBarActions, appBarMenu, header, footer, empty, fab, body];
}

/// The slot prefix of a page: its route name in lower camel case without `Route` (`MainTimelineRoute` ->
/// `mainTimeline`, `SettingsSubRoute` -> `settingsSub`).
String routeSlotPrefix(String routeName) {
  var name = routeName.endsWith('Route') ? routeName.substring(0, routeName.length - 'Route'.length) : routeName;
  if (name.endsWith('Page')) {
    name = name.substring(0, name.length - 'Page'.length);
  }
  return name.isEmpty ? name : name[0].toLowerCase() + name.substring(1);
}

/// `<page>.<part>` for a route name, e.g. `pageSlot('AlbumOptionsRoute', PluginSlotSuffix.header)`.
String pageSlot(String routeName, String suffix) =>
    '${routeSlotPrefix(routeName)}${suffix.startsWith('.') ? suffix : '.$suffix'}';

/// Hook id of a UI action (plan section 6): `action.<actionId>`.
String actionHookId(String actionId) => 'action.$actionId';

/// Overlay slots: `global` (every screen) and `route:<RouteName>` (one screen).
const globalOverlaySlot = 'global';

String routeOverlaySlot(String routeName) => 'route:$routeName';

/// Owner of app (built-in) toggles in the toggle store: keys are `app/<id>`.
const appToggleOwner = 'app';

/// Key of a toggle in the toggle store: `<owner>/<id>` (owner is a plugin name or [appToggleOwner]).
String toggleKey(String owner, String id) => '$owner/$id';

/// Splits a toggle key; a key without `/` belongs to [defaultOwner].
(String, String) parseToggleKey(String key, {required String defaultOwner}) {
  final slash = key.indexOf('/');
  if (slash <= 0 || slash == key.length - 1) {
    return (defaultOwner, key);
  }
  return (key.substring(0, slash), key.substring(slash + 1));
}

/// Prefix of plugin item ids in built-in rules (`order`, `hide`): `plugin:<plugin>/<id>`.
const pluginItemPrefix = 'plugin:';

/// The id a plugin item has in built-in rules and in `PluginBuiltins` merges.
String pluginItemId(String plugin, String id) => '$pluginItemPrefix$plugin/$id';

bool isPluginItemId(String id) => id.startsWith(pluginItemPrefix);

/// Splits `plugin:<plugin>/<id>` into `(plugin, id)`, or returns null for built-in ids.
(String, String)? parsePluginItemId(String id) {
  if (!isPluginItemId(id)) {
    return null;
  }
  final rest = id.substring(pluginItemPrefix.length);
  final slash = rest.indexOf('/');
  if (slash <= 0 || slash == rest.length - 1) {
    return null;
  }
  return (rest.substring(0, slash), rest.substring(slash + 1));
}

/// `"<plugin>#<method>"` method references used by templates and styles.
(String, String)? parseMethodRef(String ref) {
  final index = ref.indexOf('#');
  if (index <= 0 || index == ref.length - 1) {
    return null;
  }
  return (ref.substring(0, index), ref.substring(index + 1));
}

/// Whether an event name matches a subscription pattern: exact name, `*` (everything), or a prefix pattern ending in
/// `.*` (`asset.*` matches `asset.deleted` and `asset.favorite.changed`, not `asset` or `assets.x`).
bool matchesEventPattern(String pattern, String event) {
  if (pattern == '*' || pattern == event) {
    return true;
  }
  if (pattern.endsWith('.*')) {
    final prefix = pattern.substring(0, pattern.length - 1);
    return event.startsWith(prefix) && event.length > prefix.length;
  }
  return false;
}

/// Matches a slot contribution's `when` against a slot context.
///
/// * `{ "key": value }`: equal (numbers compare by value, strings case-sensitively).
/// * `{ "key": [a, b] }`: any of the values.
/// * `{ "key": { "not": x } }`: x does not match.
/// * `{ "key": { "gt" | "gte" | "lt" | "lte": n } }`: numeric comparisons (combinable).
/// * `{ "key": { "exists": true } }`: the key is (not) present and not null.
/// * `{ "key": { "contains": x } }`: list contains x, or string contains x.
/// * `{ "key": { "matches": "regex" } }`: string matches the regular expression.
/// * `{ "key": { "in": [..] } }`: same as a list.
/// * Keys may be dotted paths into the context (`"asset.exifInfo.make": "Apple"`).
/// * Top level `"not": {...}`, `"any": [{...}, ...]` and `"all": [{...}, ...]` combine conditions.
///
/// A null or empty `when` always matches. Special keys (`route`, `assetType`, `isVideo`, `isImage`, `isLocal`,
/// `isRemote`, `isFavorite`, `selectionCount`, `platform`) are read from the context like any other key; the kernel
/// fills them in (see [PluginContextKeys.derive]).
bool matchesWhen(Object? when, Map<String, dynamic> context) {
  if (when == null) {
    return true;
  }
  if (when is List) {
    return when.every((condition) => matchesWhen(condition, context));
  }
  if (when is! Map) {
    return true;
  }
  for (final MapEntry(:key, :value) in when.entries) {
    final name = '$key';
    final ok = switch (name) {
      'not' => !matchesWhen(value, context),
      'any' => value is List && value.any((condition) => matchesWhen(condition, context)),
      'all' => value is List && value.every((condition) => matchesWhen(condition, context)),
      _ => _matchesValue(value, _lookup(context, name), _has(context, name)),
    };
    if (!ok) {
      return false;
    }
  }
  return true;
}

Object? _lookup(Map<String, dynamic> context, String path) {
  if (context.containsKey(path)) {
    return context[path];
  }
  if (!path.contains('.')) {
    return null;
  }
  Object? current = context;
  for (final part in path.split('.')) {
    if (current is Map) {
      current = current[part];
    } else if (current is List) {
      final index = int.tryParse(part);
      current = index != null && index >= 0 && index < current.length ? current[index] : null;
    } else {
      return null;
    }
  }
  return current;
}

bool _has(Map<String, dynamic> context, String path) => _lookup(context, path) != null;

bool _matchesValue(Object? expected, Object? actual, bool present) {
  if (expected is List) {
    return expected.any((value) => _matchesValue(value, actual, present));
  }
  if (expected is Map) {
    for (final MapEntry(:key, :value) in expected.entries) {
      final ok = switch ('$key') {
        'not' => !_matchesValue(value, actual, present),
        'in' => value is List && value.any((item) => _equals(item, actual)),
        'exists' => (value != false) == present,
        'gt' => _compare(actual, value, (a, b) => a > b),
        'gte' => _compare(actual, value, (a, b) => a >= b),
        'lt' => _compare(actual, value, (a, b) => a < b),
        'lte' => _compare(actual, value, (a, b) => a <= b),
        'contains' => actual is List
            ? actual.any((item) => _equals(item, value))
            : actual is String && value != null && actual.contains('$value'),
        'matches' => actual != null && value is String && _regex(value)?.hasMatch('$actual') == true,
        'eq' => _equals(value, actual),
        _ => false,
      };
      if (!ok) {
        return false;
      }
    }
    return true;
  }
  return _equals(expected, actual);
}

bool _equals(Object? expected, Object? actual) {
  if (expected is num && actual is num) {
    return expected == actual;
  }
  if (expected is bool && actual is String) {
    return '$expected' == actual;
  }
  if (expected is String && actual is bool) {
    return expected == '$actual';
  }
  return expected == actual;
}

bool _compare(Object? actual, Object? expected, bool Function(num a, num b) test) {
  final a = actual is num ? actual : (actual is String ? num.tryParse(actual) : null);
  final b = expected is num ? expected : (expected is String ? num.tryParse(expected) : null);
  return a != null && b != null && test(a, b);
}

final _regexCache = <String, RegExp?>{};

RegExp? _regex(String pattern) => _regexCache.putIfAbsent(pattern, () {
  try {
    return RegExp(pattern);
  } catch (_) {
    return null;
  }
});

/// Stable short hash of a JSON-like value, used to key cached slot content per context.
int jsonHash(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => '$key').toList()..sort();
    var hash = 17;
    for (final key in keys) {
      hash = 0x1fffffff & (hash * 31 + key.hashCode);
      hash = 0x1fffffff & (hash * 31 + jsonHash(value[key]));
    }
    return hash;
  }
  if (value is List) {
    var hash = 19;
    for (final item in value) {
      hash = 0x1fffffff & (hash * 31 + jsonHash(item));
    }
    return hash;
  }
  return value.hashCode & 0x1fffffff;
}
