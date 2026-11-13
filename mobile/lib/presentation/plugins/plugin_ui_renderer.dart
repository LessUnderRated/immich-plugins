import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/presentation/plugins/plugin_icons.dart';
import 'package:immich_mobile/presentation/plugins/plugin_ui.dart';
import 'package:immich_mobile/presentation/plugins/plugin_ui_editors.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/providers/plugin_kernel.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('PluginUi');

// -------------------------------------------------------------------------------------------------------------------
// Value helpers (shared with plugin_slot.dart)
// -------------------------------------------------------------------------------------------------------------------

/// A color from `#AARRGGBB` / `#RRGGBB`, or a theme token (`primary`, `onSurfaceVariant`, `surfaceContainerHigh`,
/// `error`, ... any `ColorScheme` field, plus `transparent`, `white`, `black`), optionally with `@alpha`
/// (`primary@0.5`).
Color? pluginColor(BuildContext context, Object? value) {
  if (value is int) {
    return Color(value);
  }
  if (value is! String || value.isEmpty) {
    return null;
  }
  final at = value.indexOf('@');
  final name = at == -1 ? value : value.substring(0, at);
  final alpha = at == -1 ? null : double.tryParse(value.substring(at + 1));
  final parsed = parsePluginColor(name);
  final color = parsed != null ? Color(parsed) : pluginThemeColor(Theme.of(context).colorScheme, name);
  return alpha == null || color == null ? color : color.withValues(alpha: alpha.clamp(0.0, 1.0));
}

/// A `ColorScheme` token by name.
Color? pluginThemeColor(ColorScheme scheme, String name) => switch (name) {
  'primary' => scheme.primary,
  'onPrimary' => scheme.onPrimary,
  'primaryContainer' => scheme.primaryContainer,
  'onPrimaryContainer' => scheme.onPrimaryContainer,
  'primaryFixed' => scheme.primaryFixed,
  'primaryFixedDim' => scheme.primaryFixedDim,
  'onPrimaryFixed' => scheme.onPrimaryFixed,
  'onPrimaryFixedVariant' => scheme.onPrimaryFixedVariant,
  'secondary' => scheme.secondary,
  'onSecondary' => scheme.onSecondary,
  'secondaryContainer' => scheme.secondaryContainer,
  'onSecondaryContainer' => scheme.onSecondaryContainer,
  'tertiary' => scheme.tertiary,
  'onTertiary' => scheme.onTertiary,
  'tertiaryContainer' => scheme.tertiaryContainer,
  'onTertiaryContainer' => scheme.onTertiaryContainer,
  'error' => scheme.error,
  'onError' => scheme.onError,
  'errorContainer' => scheme.errorContainer,
  'onErrorContainer' => scheme.onErrorContainer,
  'surface' => scheme.surface,
  'onSurface' => scheme.onSurface,
  'onSurfaceVariant' => scheme.onSurfaceVariant,
  'surfaceDim' => scheme.surfaceDim,
  'surfaceBright' => scheme.surfaceBright,
  'surfaceContainerLowest' => scheme.surfaceContainerLowest,
  'surfaceContainerLow' => scheme.surfaceContainerLow,
  'surfaceContainer' => scheme.surfaceContainer,
  'surfaceContainerHigh' => scheme.surfaceContainerHigh,
  'surfaceContainerHighest' => scheme.surfaceContainerHighest,
  'surfaceTint' => scheme.surfaceTint,
  'outline' => scheme.outline,
  'outlineVariant' => scheme.outlineVariant,
  'shadow' => scheme.shadow,
  'scrim' => scheme.scrim,
  'inverseSurface' => scheme.inverseSurface,
  'onInverseSurface' => scheme.onInverseSurface,
  'inversePrimary' => scheme.inversePrimary,
  'transparent' => const Color(0x00000000),
  'white' => const Color(0xFFFFFFFF),
  'black' => const Color(0xFF000000),
  _ => null,
};

/// Every color scheme token as `#AARRGGBB` (sent to plugin views as `params.theme.colors`).
Map<String, String> pluginColorTokens(ColorScheme scheme) => {
  for (final name in const [
    'primary',
    'onPrimary',
    'primaryContainer',
    'onPrimaryContainer',
    'secondary',
    'onSecondary',
    'secondaryContainer',
    'onSecondaryContainer',
    'tertiary',
    'onTertiary',
    'tertiaryContainer',
    'onTertiaryContainer',
    'error',
    'onError',
    'errorContainer',
    'onErrorContainer',
    'surface',
    'onSurface',
    'onSurfaceVariant',
    'surfaceDim',
    'surfaceBright',
    'surfaceContainerLowest',
    'surfaceContainerLow',
    'surfaceContainer',
    'surfaceContainerHigh',
    'surfaceContainerHighest',
    'outline',
    'outlineVariant',
    'shadow',
    'scrim',
    'inverseSurface',
    'onInverseSurface',
    'inversePrimary',
  ])
    name: pluginColorHex(pluginThemeColor(scheme, name)!),
};

/// Theme info for plugin native views: `{ brightness, isDark, colors: { token: "#AARRGGBB" }, fontFamily,
/// textScale, density }`.
Map<String, dynamic> pluginThemeInfo(BuildContext context) {
  final theme = Theme.of(context);
  final media = MediaQuery.maybeOf(context);
  return {
    'brightness': theme.brightness.name,
    'isDark': theme.brightness == Brightness.dark,
    'colors': pluginColorTokens(theme.colorScheme),
    'fontFamily': theme.textTheme.bodyMedium?.fontFamily,
    'textScale': media?.textScaler.scale(1) ?? 1,
    'density': media?.devicePixelRatio ?? 1,
  };
}

EdgeInsets? pluginInsets(Object? value) {
  if (value is num) {
    return EdgeInsets.all(value.toDouble());
  }
  if (value is List && value.every((item) => item is num)) {
    final numbers = [for (final item in value) (item as num).toDouble()];
    return switch (numbers.length) {
      1 => EdgeInsets.all(numbers[0]),
      2 => EdgeInsets.symmetric(horizontal: numbers[0], vertical: numbers[1]),
      4 => EdgeInsets.fromLTRB(numbers[0], numbers[1], numbers[2], numbers[3]),
      _ => null,
    };
  }
  if (value is Map) {
    double read(String key) => (value[key] as num?)?.toDouble() ?? 0;
    return EdgeInsets.fromLTRB(
      read('left') + read('horizontal'),
      read('top') + read('vertical'),
      read('right') + read('horizontal'),
      read('bottom') + read('vertical'),
    );
  }
  return null;
}

Alignment? pluginAlignment(Object? value) {
  if (value is List && value.length == 2 && value.every((item) => item is num)) {
    return Alignment((value[0] as num).toDouble(), (value[1] as num).toDouble());
  }
  return switch (value) {
    'topLeft' || 'topStart' => Alignment.topLeft,
    'topCenter' || 'top' => Alignment.topCenter,
    'topRight' || 'topEnd' => Alignment.topRight,
    'centerLeft' || 'left' || 'start' => Alignment.centerLeft,
    'center' => Alignment.center,
    'centerRight' || 'right' || 'end' => Alignment.centerRight,
    'bottomLeft' || 'bottomStart' => Alignment.bottomLeft,
    'bottomCenter' || 'bottom' => Alignment.bottomCenter,
    'bottomRight' || 'bottomEnd' => Alignment.bottomRight,
    _ => null,
  };
}

MainAxisAlignment _mainAxis(Object? value) => switch (value) {
  'end' => MainAxisAlignment.end,
  'center' => MainAxisAlignment.center,
  'spaceBetween' => MainAxisAlignment.spaceBetween,
  'spaceAround' => MainAxisAlignment.spaceAround,
  'spaceEvenly' => MainAxisAlignment.spaceEvenly,
  _ => MainAxisAlignment.start,
};

CrossAxisAlignment _crossAxis(Object? value, CrossAxisAlignment fallback) => switch (value) {
  'start' => CrossAxisAlignment.start,
  'end' => CrossAxisAlignment.end,
  'center' => CrossAxisAlignment.center,
  'stretch' => CrossAxisAlignment.stretch,
  _ => fallback,
};

BoxFit _fit(Object? value, BoxFit fallback) => switch (value) {
  'contain' => BoxFit.contain,
  'cover' => BoxFit.cover,
  'fill' => BoxFit.fill,
  'fitWidth' => BoxFit.fitWidth,
  'fitHeight' => BoxFit.fitHeight,
  'none' => BoxFit.none,
  'scaleDown' => BoxFit.scaleDown,
  _ => fallback,
};

TextStyle? _textToken(TextTheme theme, Object? value) => switch (value) {
  'displayLarge' => theme.displayLarge,
  'displayMedium' => theme.displayMedium,
  'displaySmall' => theme.displaySmall,
  'headlineLarge' => theme.headlineLarge,
  'headlineMedium' => theme.headlineMedium,
  'headlineSmall' => theme.headlineSmall,
  'titleLarge' => theme.titleLarge,
  'titleMedium' => theme.titleMedium,
  'titleSmall' => theme.titleSmall,
  'bodyLarge' => theme.bodyLarge,
  'bodyMedium' => theme.bodyMedium,
  'bodySmall' => theme.bodySmall,
  'labelLarge' => theme.labelLarge,
  'labelMedium' => theme.labelMedium,
  'labelSmall' => theme.labelSmall,
  _ => null,
};

FontWeight? _weight(Object? value) => switch (value) {
  'thin' || 100 => FontWeight.w100,
  'extraLight' || 200 => FontWeight.w200,
  'light' || 300 => FontWeight.w300,
  'normal' || 'regular' || 400 => FontWeight.w400,
  'medium' || 500 => FontWeight.w500,
  'semiBold' || 'semibold' || 600 => FontWeight.w600,
  'bold' || 700 => FontWeight.w700,
  'extraBold' || 800 => FontWeight.w800,
  'black' || 900 => FontWeight.w900,
  _ => null,
};

double? _double(Object? value) => value is num ? value.toDouble() : (value is String ? double.tryParse(value) : null);

int? _int(Object? value) => value is num ? value.toInt() : (value is String ? int.tryParse(value) : null);

String? _string(Object? value) => value == null ? null : '$value';

bool _bool(Object? value, [bool fallback = false]) => value is bool ? value : fallback;

Map<String, dynamic> _map(Object? value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

/// `options` of choice inputs: `[{ "value", "label"?, "icon"? }]` or plain values.
List<({Object? value, String label, String? icon})> _options(Object? value) => [
  for (final option in value is List ? value : const [])
    option is Map
        ? (value: option['value'], label: '${option['label'] ?? option['value']}', icon: option['icon'] as String?)
        : (value: option, label: '$option', icon: null),
];

// -------------------------------------------------------------------------------------------------------------------
// Surface view
// -------------------------------------------------------------------------------------------------------------------

/// Reads the input state of a [PluginUiView] from outside (dialogs and sheets return it).
class PluginUiController {
  _PluginUiViewState? _view;

  /// Current input values by input id.
  Map<String, dynamic> get state => _view?._stateJson() ?? const {};

  /// The surface id plugins target with `ui.update` / `ui.patch`.
  String? get surfaceId => _view?._surface.id;

  /// Sends a UI event as if a node fired it.
  Future<void> send(String event, {String? id, Object? value, Map<String, dynamic>? action}) async =>
      _view?._send(event, id: id, value: value, action: action);
}

/// Renders a JSON UI tree with the app's theme (plan section 3.4) and keeps it in sync with its plugin.
///
/// The tree comes from [ui] or, when [ui] is null, from calling [method] with `PageV1`
/// `{ "page", "params", "surface", "context" }`. Interactions call the node's action method (or [method]) with
/// `UiEventV1` `{ "surface", "event", "id", "value", "state", "context", "page", "params" }`; the response may carry
/// `ui` (replaces the tree), `state` (replaces input values), `message`, `actions`, `title`, `appBarActions`, `fab`
/// and `close` (closes the page / dialog / sheet with that result). The plugin can also push changes at any time with
/// `ui.update` / `ui.patch` / `ui.setState` on the surface id.
class PluginUiView extends ConsumerStatefulWidget {
  final String plugin;
  final Map<String, dynamic>? ui;
  final String? method;
  final String? page;
  final Map<String, dynamic> params;

  /// Sent as `context` with every event (where the surface is: slot context, asset, ...).
  final Map<String, dynamic> eventContext;

  /// Surface id; default `page:<page or method>`.
  final String? surface;
  final Map<String, dynamic>? initialState;
  final void Function(Object? result)? onClose;

  /// Wrap trees that do not scroll themselves in a scroll view (pages, sheets).
  final bool scrollable;
  final EdgeInsetsGeometry? padding;

  /// Render as a page: Scaffold with an app bar ([title], plugin `appBarActions`) and a plugin `fab`.
  final bool pageChrome;
  final String? title;
  final PluginUiController? controller;

  const PluginUiView({
    super.key,
    required this.plugin,
    this.ui,
    this.method,
    this.page,
    this.params = const {},
    this.eventContext = const {},
    this.surface,
    this.initialState,
    this.onClose,
    this.scrollable = false,
    this.padding,
    this.pageChrome = false,
    this.title,
    this.controller,
  });

  @override
  ConsumerState<PluginUiView> createState() => _PluginUiViewState();
}

class _PluginUiViewState extends ConsumerState<PluginUiView> {
  late final PluginKernel _kernel;
  late PluginUiSurface _surface;
  final Map<String, Object?> _values = {};
  final Map<String, int> _nodeValues = {};
  final Map<String, TextEditingController> _texts = {};
  final Map<String, Timer> _debounce = {};
  final Map<String, Future<BaseAsset?>> _assets = {};
  var _busy = 0;
  var _loading = false;
  Object? _error;
  String? _title;
  List<Map<String, dynamic>> _appBarActions = const [];
  Map<String, dynamic>? _fab;
  String? _root;

  String get _defaultSurface => 'page:${widget.page ?? widget.method ?? 'ui'}';

  @override
  void initState() {
    super.initState();
    _kernel = ref.read(pluginKernelProvider);
    widget.controller?._view = this;
    _attach();
  }

  void _attach() {
    _surface = _kernel.surfaces.attach(widget.plugin, widget.surface ?? _defaultSurface);
    _surface.addListener(_onSurface);
    if (_surface.tree != null) {
      _sync();
    } else if (widget.ui != null) {
      _surface.setTree(widget.ui, state: widget.initialState, notify: false);
      _sync();
    } else if (widget.method != null) {
      unawaited(_load());
    }
  }

  void _detach() {
    _surface.removeListener(_onSurface);
    _kernel.surfaces.detach(_surface);
  }

  @override
  void didUpdateWidget(PluginUiView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._view = null;
      widget.controller?._view = this;
    }
    if ((widget.surface ?? _defaultSurface) != _surface.id || widget.plugin != _surface.plugin) {
      _detach();
      _values.clear();
      _nodeValues.clear();
      _attach();
      return;
    }
    final ui = widget.ui;
    if (ui != null && jsonHash(ui) != jsonHash(oldWidget.ui)) {
      _surface.setTree(ui, notify: false);
      _sync();
    }
  }

  @override
  void dispose() {
    if (widget.controller?._view == this) {
      widget.controller?._view = null;
    }
    _detach();
    for (final timer in _debounce.values) {
      timer.cancel();
    }
    for (final controller in _texts.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final method = widget.method;
    if (method == null) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await _kernel.call(widget.plugin, method, PluginCallType.page, {
        'page': widget.page ?? method,
        'params': widget.params,
        'surface': _surface.id,
        'context': widget.eventContext,
      });
      if (!mounted) {
        return;
      }
      setState(() => _loading = false);
      await _applyResponse(response);
    } catch (error, stack) {
      _log.warning('Page ${widget.plugin}/${widget.page ?? method} failed', error, stack);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    }
  }

  void _onSurface() {
    if (mounted) {
      setState(_sync);
    }
  }

  /// Applies `value`s of input nodes that changed in the tree, then values the plugin pushed.
  void _sync() {
    void visit(Object? node) {
      if (node is Map) {
        final id = node['id'];
        if (id is String && node['type'] != null && node.containsKey('value')) {
          final hash = jsonHash(node['value']);
          if (_nodeValues[id] != hash) {
            _nodeValues[id] = hash;
            _setLocal(id, node['value']);
          }
        }
        node.values.forEach(visit);
      } else if (node is List) {
        node.forEach(visit);
      }
    }

    visit(_surface.tree);
    for (final MapEntry(:key, :value) in _surface.takeState().entries) {
      _setLocal(key, value);
    }
  }

  void _setLocal(String id, Object? value) {
    _values[id] = value;
    final text = _texts[id];
    final string = value == null ? '' : '$value';
    if (text != null && text.text != string) {
      text.value = TextEditingValue(text: string, selection: TextSelection.collapsed(offset: string.length));
    }
  }

  Map<String, dynamic> _stateJson() => {
    for (final MapEntry(:key, :value) in _values.entries) key: value,
  };

  Future<void> _applyResponse(Map<String, dynamic>? response) async {
    if (response == null || !mounted) {
      return;
    }
    final ui = response['ui'];
    final state = response['state'];
    if (ui is Map) {
      _surface.setTree(Map<String, dynamic>.from(ui), state: state is Map ? Map<String, dynamic>.from(state) : null);
    } else if (state is Map) {
      _surface.pushState(Map<String, dynamic>.from(state));
    }
    final title = response['title'];
    final appBarActions = response['appBarActions'];
    final fab = response['fab'];
    if (title is String || appBarActions is List || fab is Map || response.containsKey('fab')) {
      setState(() {
        if (title is String) {
          _title = title;
        }
        if (appBarActions is List) {
          _appBarActions = [for (final action in appBarActions.whereType<Map>()) Map<String, dynamic>.from(action)];
        }
        if (response.containsKey('fab')) {
          _fab = fab is Map ? Map<String, dynamic>.from(fab) : null;
        }
      });
    }
    final actions = response['actions'];
    for (final action in (actions is List ? actions : const []).whereType<Map>()) {
      await _command(Map<String, dynamic>.from(action));
    }
    final message = response['message'];
    if (message is String && message.isNotEmpty) {
      await _kernel.command(widget.plugin, {'type': 'toast', 'message': message});
    }
    if (response.containsKey('close')) {
      widget.onClose?.call(response['close']);
    }
  }

  static Map<String, dynamic> _actionOf(Object? spec) => switch (spec) {
    final String method => {'method': method},
    final Map map => Map<String, dynamic>.from(map),
    _ => <String, dynamic>{},
  };

  Future<void> _run(Object? spec, {String event = 'tap', String? id, Object? value}) async {
    if (spec == null || spec == false) {
      return;
    }
    final action = _actionOf(spec);
    final command = action['command'] ?? (action['type'] is String ? action : null);
    if (command is Map) {
      await _command(Map<String, dynamic>.from(command));
      return;
    }
    final commands = action['commands'];
    if (commands is List) {
      for (final item in commands.whereType<Map>()) {
        await _command(Map<String, dynamic>.from(item));
      }
      return;
    }
    await _send(event, id: id, value: value, action: action);
  }

  Future<void> _command(Map<String, dynamic> command) async {
    switch (command['type']) {
      case 'close':
        widget.onClose?.call(command['result'] ?? command['value']);
        return;
      case 'setState':
        final state = command['state'];
        if (state is Map) {
          _surface.pushState(Map<String, dynamic>.from(state));
        }
        return;
      case 'reload':
        await _load();
        return;
    }
    if (!mounted) {
      return;
    }
    await _kernel.command(widget.plugin, command, context: context);
  }

  Future<void> _send(String event, {String? id, Object? value, Map<String, dynamic>? action}) async {
    final method = (action?['method'] as String?) ?? widget.method;
    if (method == null) {
      return;
    }
    setState(() => _busy++);
    try {
      final response = await _kernel.call(widget.plugin, method, PluginCallType.uiEvent, {
        'surface': _surface.id,
        'event': event,
        'id': id,
        'value': value,
        'state': _stateJson(),
        'context': widget.eventContext,
        'page': widget.page,
        'params': {...widget.params, ..._map(action?['params'])},
      });
      await _applyResponse(response);
    } catch (error, stack) {
      _log.warning('UI event $event of ${widget.plugin} failed', error, stack);
      unawaited(_kernel.command(widget.plugin, {'type': 'toast', 'message': '$error'}));
    } finally {
      if (mounted) {
        setState(() => _busy--);
      }
    }
  }

  Object? _value(Map<String, dynamic> node, [Object? fallback]) {
    final id = node['id'];
    if (id is String && _values.containsKey(id)) {
      return _values[id];
    }
    return node['value'] ?? fallback;
  }

  void _change(Map<String, dynamic> node, Object? value, {bool debounce = false, String event = 'change'}) {
    final id = node['id'] as String?;
    setState(() {
      if (id != null) {
        _values[id] = value;
      }
    });
    final onChange = node['onChange'];
    if (onChange == null || onChange == false) {
      return;
    }
    final action = onChange == true ? const <String, dynamic>{} : _actionOf(onChange);
    final key = id ?? '${node.hashCode}';
    _debounce.remove(key)?.cancel();
    if (debounce) {
      _debounce[key] = Timer(const Duration(milliseconds: 250), () {
        _debounce.remove(key);
        unawaited(_send(event, id: id, value: value, action: action));
      });
    } else {
      unawaited(_send(event, id: id, value: value, action: action));
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Nodes
  // ---------------------------------------------------------------------------------------------------------------

  static const _parentData = {'expanded', 'flexible', 'spacer', 'positioned'};

  Widget _build(Object? raw) {
    if (raw is! Map) {
      return raw is String ? Text(raw) : const SizedBox.shrink();
    }
    final node = raw is Map<String, dynamic> ? raw : Map<String, dynamic>.from(raw);
    if (node['visible'] == false) {
      return const SizedBox.shrink();
    }
    try {
      final widget = _buildNode(node);
      return _parentData.contains(node['type']) ? widget : _decorate(node, widget);
    } catch (error, stack) {
      _log.warning('JSON UI node ${node['type']} of ${this.widget.plugin} failed', error, stack);
      return _NodeError(type: '${node['type']}', error: error);
    }
  }

  Widget _decorate(Map<String, dynamic> node, Widget widget) {
    var result = widget;
    const ownPadding = {'container', 'padding', 'card', 'list', 'grid', 'scroll', 'listTile', 'section', 'group'};
    final padding = ownPadding.contains(node['type']) ? null : pluginInsets(node['padding']);
    if (padding != null) {
      result = Padding(padding: padding, child: result);
    }
    final onTap = node['onTap'];
    final onLongPress = node['onLongPress'];
    if ((onTap != null || onLongPress != null) && node['type'] != 'gesture') {
      result = InkWell(
        onTap: onTap == null ? null : () => unawaited(_run(onTap, id: node['id'] as String?)),
        onLongPress: onLongPress == null
            ? null
            : () => unawaited(_run(onLongPress, event: 'longPress', id: node['id'] as String?)),
        child: result,
      );
    }
    final opacity = _double(node['opacity']);
    if (opacity != null) {
      result = Opacity(opacity: opacity.clamp(0.0, 1.0), child: result);
    }
    final tooltip = node['tooltip'];
    if (tooltip is String && node['type'] != 'iconButton' && node['type'] != 'tooltip') {
      result = Tooltip(message: tooltip, child: result);
    }
    final margin = pluginInsets(node['margin']);
    if (margin != null) {
      result = Padding(padding: margin, child: result);
    }
    return result;
  }

  List<Widget> _kids(Map<String, dynamic> node, [String key = 'children']) => [
    for (final child in node[key] is List ? node[key] as List : const []) _build(child),
  ];

  Widget? _child(Map<String, dynamic> node, [String key = 'child']) {
    final child = node[key];
    if (child == null) {
      final children = node['children'];
      return key == 'child' && children is List && children.isNotEmpty ? _build(children.first) : null;
    }
    return _build(child);
  }

  /// A node, a string (text), or null.
  Widget? _content(Object? value, {TextStyle? style}) => switch (value) {
    null => null,
    final String text => Text(text, style: style),
    final Map _ => _build(value),
    _ => Text('$value', style: style),
  };

  /// An icon name / file, or a node.
  Widget? _icon(Object? value, {Color? color, double? size}) => switch (value) {
    null => null,
    final String name => PluginIcon(plugin: widget.plugin, icon: name, color: color, size: size),
    final Map _ => _build(value),
    _ => null,
  };

  TextStyle? _textStyle(Map<String, dynamic> node) {
    final theme = Theme.of(context).textTheme;
    final base = _textToken(theme, node['style']);
    final color = pluginColor(context, node['color']);
    final weight = _weight(node['weight']);
    final size = _double(node['size']);
    final italic = node['italic'] == true;
    final underline = node['underline'] == true;
    final strike = node['strikethrough'] == true;
    if (base == null && color == null && weight == null && size == null && !italic && !underline && !strike) {
      return null;
    }
    return (base ?? const TextStyle()).copyWith(
      color: color,
      fontWeight: weight,
      fontSize: size,
      fontStyle: italic ? FontStyle.italic : null,
      fontFamily: node['fontFamily'] as String?,
      decoration: underline ? TextDecoration.underline : (strike ? TextDecoration.lineThrough : null),
    );
  }

  String? _resolveFile(Map<String, dynamic> node) {
    final file = node['file'] ?? node['path'];
    if (file is! String) {
      return null;
    }
    return File(file).isAbsolute || _root == null ? file : resolvePluginFile(_root!, widget.plugin, file);
  }

  Future<BaseAsset?> _asset(String id) => _assets.putIfAbsent(id, () => _kernel.findAsset(id));

  Widget _buildNode(Map<String, dynamic> n) {
    final type = '${n['type'] ?? ''}';
    switch (type) {
      // ---- layout -------------------------------------------------------------------------------------------------
      case 'column':
        return Column(
          mainAxisSize: n['expand'] == true ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: _mainAxis(n['mainAxis'] ?? n['mainAxisAlignment']),
          crossAxisAlignment: _crossAxis(n['crossAxis'] ?? n['crossAxisAlignment'], CrossAxisAlignment.stretch),
          spacing: _double(n['spacing'] ?? n['gap']) ?? 0,
          children: _kids(n),
        );
      case 'row':
        return Row(
          mainAxisSize: n['shrink'] == true ? MainAxisSize.min : MainAxisSize.max,
          mainAxisAlignment: _mainAxis(n['mainAxis'] ?? n['mainAxisAlignment']),
          crossAxisAlignment: _crossAxis(n['crossAxis'] ?? n['crossAxisAlignment'], CrossAxisAlignment.center),
          spacing: _double(n['spacing'] ?? n['gap']) ?? 0,
          children: _kids(n),
        );
      case 'stack':
        return Stack(
          alignment: pluginAlignment(n['alignment']) ?? Alignment.topLeft,
          fit: n['fit'] == 'expand' ? StackFit.expand : StackFit.loose,
          children: _kids(n),
        );
      case 'positioned':
        return Positioned(
          left: _double(n['left']),
          top: _double(n['top']),
          right: _double(n['right']),
          bottom: _double(n['bottom']),
          width: _double(n['width']),
          height: _double(n['height']),
          child: _child(n) ?? const SizedBox.shrink(),
        );
      case 'wrap':
        return Wrap(
          spacing: _double(n['spacing']) ?? 8,
          runSpacing: _double(n['runSpacing']) ?? _double(n['spacing']) ?? 8,
          alignment: switch (n['alignment']) {
            'center' => WrapAlignment.center,
            'end' => WrapAlignment.end,
            'spaceBetween' => WrapAlignment.spaceBetween,
            _ => WrapAlignment.start,
          },
          crossAxisAlignment: WrapCrossAlignment.center,
          children: _kids(n),
        );
      case 'padding':
        return Padding(padding: pluginInsets(n['padding']) ?? const EdgeInsets.all(8), child: _child(n));
      case 'center':
        return Center(child: _child(n));
      case 'align':
        return Align(alignment: pluginAlignment(n['alignment']) ?? Alignment.center, child: _child(n));
      case 'expanded':
        return Expanded(flex: _int(n['flex']) ?? 1, child: _child(n) ?? const SizedBox.shrink());
      case 'flexible':
        return Flexible(
          flex: _int(n['flex']) ?? 1,
          fit: n['fit'] == 'tight' ? FlexFit.tight : FlexFit.loose,
          child: _child(n) ?? const SizedBox.shrink(),
        );
      case 'spacer':
        return Spacer(flex: _int(n['flex']) ?? 1);
      case 'sizedBox':
        return SizedBox(width: _double(n['width']), height: _double(n['height']), child: _child(n));
      case 'aspectRatio':
        return AspectRatio(aspectRatio: _double(n['ratio'] ?? n['aspectRatio']) ?? 1, child: _child(n));
      case 'container':
        final radius = _double(n['radius']);
        final border = n['border'];
        final gradient = n['gradient'];
        final colors = gradient is Map ? [for (final c in gradient['colors'] as List? ?? const []) pluginColor(context, c)] : null;
        return Container(
          width: _double(n['width']),
          height: _double(n['height']),
          alignment: pluginAlignment(n['alignment']),
          padding: pluginInsets(n['padding']),
          clipBehavior: radius != null ? Clip.antiAlias : Clip.none,
          decoration: BoxDecoration(
            color: pluginColor(context, n['color']),
            borderRadius: radius == null ? null : BorderRadius.all(Radius.circular(radius)),
            border: border is Map
                ? Border.all(
                    color: pluginColor(context, border['color']) ?? Theme.of(context).colorScheme.outline,
                    width: _double(border['width']) ?? 1,
                  )
                : (border == true ? Border.all(color: Theme.of(context).colorScheme.outlineVariant) : null),
            gradient: colors != null && colors.nonNulls.length >= 2
                ? LinearGradient(
                    colors: colors.nonNulls.toList(),
                    begin: pluginAlignment((gradient as Map)['begin']) ?? Alignment.topCenter,
                    end: pluginAlignment(gradient['end']) ?? Alignment.bottomCenter,
                  )
                : null,
          ),
          child: _child(n),
        );
      case 'card':
        final child = Padding(padding: pluginInsets(n['padding']) ?? const EdgeInsets.all(12), child: _child(n));
        final color = pluginColor(context, n['color']);
        return switch (n['variant']) {
          'outlined' => Card.outlined(color: color, child: child),
          'filled' => Card.filled(color: color, child: child),
          _ => Card(color: color, elevation: _double(n['elevation']), child: child),
        };
      case 'scroll':
        return SingleChildScrollView(
          scrollDirection: n['direction'] == 'horizontal' ? Axis.horizontal : Axis.vertical,
          padding: pluginInsets(n['padding']),
          child: _child(n),
        );
      case 'list':
        final items = n['children'] ?? n['items'];
        final list = items is List ? items : const [];
        final root = identical(n, _surface.tree) && widget.scrollable;
        final separated = n['separated'] == true;
        Widget item(BuildContext context, int index) => _build(list[index]);
        return separated
            ? ListView.separated(
                shrinkWrap: !root,
                physics: root ? null : const NeverScrollableScrollPhysics(),
                padding: pluginInsets(n['padding']),
                itemCount: list.length,
                itemBuilder: item,
                separatorBuilder: (_, _) => const Divider(height: 1),
              )
            : ListView.builder(
                shrinkWrap: !root,
                physics: root ? null : const NeverScrollableScrollPhysics(),
                padding: pluginInsets(n['padding']),
                itemExtent: _double(n['itemExtent']),
                itemCount: list.length,
                itemBuilder: item,
              );
      case 'grid':
        final items = n['children'] ?? n['items'];
        final list = items is List ? items : const [];
        final root = identical(n, _surface.tree) && widget.scrollable;
        final spacing = _double(n['spacing']) ?? 4;
        final maxExtent = _double(n['maxExtent']);
        return GridView.builder(
          shrinkWrap: !root,
          physics: root ? null : const NeverScrollableScrollPhysics(),
          padding: pluginInsets(n['padding']),
          gridDelegate: maxExtent != null
              ? SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: maxExtent,
                  mainAxisSpacing: spacing,
                  crossAxisSpacing: spacing,
                  childAspectRatio: _double(n['aspectRatio']) ?? 1,
                )
              : SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _int(n['columns']) ?? 3,
                  mainAxisSpacing: spacing,
                  crossAxisSpacing: spacing,
                  childAspectRatio: _double(n['aspectRatio']) ?? 1,
                ),
          itemCount: list.length,
          itemBuilder: (context, index) => _build(list[index]),
        );
      case 'divider':
        return Divider(
          height: _double(n['height']),
          thickness: _double(n['thickness']),
          indent: _double(n['indent']),
          endIndent: _double(n['endIndent']),
          color: pluginColor(context, n['color']),
        );
      case 'verticalDivider':
        return VerticalDivider(width: _double(n['width']), color: pluginColor(context, n['color']));
      case 'safeArea':
        return SafeArea(child: _child(n) ?? const SizedBox.shrink());
      case 'clip':
        return ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(_double(n['radius']) ?? 12)),
          child: _child(n),
        );
      case 'section':
      case 'group':
        return _section(n);

      // ---- content ------------------------------------------------------------------------------------------------
      case 'text':
        final text = '${n['text'] ?? n['value'] ?? ''}';
        final style = _textStyle(n);
        final align = switch (n['align']) {
          'center' => TextAlign.center,
          'end' || 'right' => TextAlign.end,
          'justify' => TextAlign.justify,
          _ => null,
        };
        final maxLines = _int(n['maxLines']);
        return n['selectable'] == true
            ? SelectableText(text, style: style, textAlign: align, maxLines: maxLines)
            : Text(
                text,
                style: style,
                textAlign: align,
                maxLines: maxLines,
                overflow: maxLines == null ? null : TextOverflow.ellipsis,
              );
      case 'icon':
        return _icon(
              n['icon'] ?? n['name'],
              color: pluginColor(context, n['color']),
              size: _double(n['size']),
            ) ??
            const SizedBox.shrink();
      case 'image':
        return _image(n);
      case 'assetThumbnail':
      case 'assetImage':
        return _assetImage(n, full: type == 'assetImage');
      case 'progress':
        final value = _double(n['value']);
        final color = pluginColor(context, n['color']);
        return n['variant'] == 'circular' || n['circular'] == true
            ? Center(
                child: SizedBox.square(
                  dimension: _double(n['size']) ?? 32,
                  child: CircularProgressIndicator(value: value, color: color),
                ),
              )
            : LinearProgressIndicator(value: value, color: color, minHeight: _double(n['height']) ?? 4);
      case 'badge':
        final label = n['label'] ?? n['text'];
        return Badge(
          label: label == null ? null : Text('$label'),
          isLabelVisible: n['visible'] != false,
          backgroundColor: pluginColor(context, n['color']),
          textColor: pluginColor(context, n['textColor']),
          child: _child(n),
        );
      case 'avatar':
        final file = _resolveFile(n);
        final url = n['url'] as String?;
        return CircleAvatar(
          radius: _double(n['radius']) ?? 20,
          backgroundColor: pluginColor(context, n['color']),
          foregroundColor: pluginColor(context, n['textColor']),
          backgroundImage: file != null ? FileImage(File(file)) : (url != null ? NetworkImage(url) : null),
          child: n['icon'] != null ? _icon(n['icon']) : (n['text'] != null ? Text('${n['text']}') : null),
        );
      case 'tooltip':
        return Tooltip(message: '${n['message'] ?? n['text'] ?? ''}', child: _child(n));
      case 'nativeView':
        final height = _double(n['height']);
        final view = PluginView(
          plugin: '${n['plugin'] ?? widget.plugin}',
          view: '${n['view']}',
          params: _map(n['params']),
          composition: n['composition'] as String?,
          interactive: n['interactive'] != false,
          height: height,
          defaultHeight: 200,
        );
        return view;

      // ---- input --------------------------------------------------------------------------------------------------
      case 'button':
        return _button(n);
      case 'iconButton':
        final onPressed = n['enabled'] == false ? null : () => unawaited(_run(n['action'], id: n['id'] as String?));
        final icon = _icon(n['icon'], color: pluginColor(context, n['color'])) ?? const Icon(Icons.extension_outlined);
        final selected = n['selected'] is bool ? n['selected'] as bool : null;
        final selectedIcon = _icon(n['selectedIcon']);
        final tooltip = n['tooltip'] as String?;
        return switch (n['style']) {
          'filled' => IconButton.filled(
            onPressed: onPressed,
            icon: icon,
            tooltip: tooltip,
            isSelected: selected,
            selectedIcon: selectedIcon,
          ),
          'tonal' => IconButton.filledTonal(
            onPressed: onPressed,
            icon: icon,
            tooltip: tooltip,
            isSelected: selected,
            selectedIcon: selectedIcon,
          ),
          'outlined' => IconButton.outlined(
            onPressed: onPressed,
            icon: icon,
            tooltip: tooltip,
            isSelected: selected,
            selectedIcon: selectedIcon,
          ),
          _ => IconButton(
            onPressed: onPressed,
            icon: icon,
            tooltip: tooltip,
            isSelected: selected,
            selectedIcon: selectedIcon,
          ),
        };
      case 'fab':
        final label = n['label'];
        final onPressed = () => unawaited(_run(n['action'], id: n['id'] as String?));
        final icon = _icon(n['icon']) ?? const Icon(Icons.add);
        return label == null
            ? FloatingActionButton(heroTag: null, onPressed: onPressed, tooltip: n['tooltip'] as String?, child: icon)
            : FloatingActionButton.extended(heroTag: null, onPressed: onPressed, icon: icon, label: Text('$label'));
      case 'listTile':
        final action = n['action'];
        return ListTile(
          title: _content(n['title']),
          subtitle: _content(n['subtitle']),
          leading: _icon(n['leading'] ?? n['icon']),
          trailing: _icon(n['trailing']) ?? (action != null && n['chevron'] == true ? const Icon(Icons.chevron_right) : null),
          dense: n['dense'] == true,
          enabled: n['enabled'] != false,
          selected: n['selected'] == true,
          contentPadding: pluginInsets(n['padding']),
          onTap: action == null ? null : () => unawaited(_run(action, id: n['id'] as String?)),
          onLongPress: n['onLongPress'] == null
              ? null
              : () => unawaited(_run(n['onLongPress'], event: 'longPress', id: n['id'] as String?)),
        );
      case 'switch':
      case 'switchTile':
        final value = _value(n, false) == true;
        final onChanged = n['enabled'] == false ? null : (bool next) => _change(n, next);
        final title = n['label'] ?? n['title'];
        return title == null && type == 'switch'
            ? Align(alignment: Alignment.centerLeft, child: Switch(value: value, onChanged: onChanged))
            : SwitchListTile(
                value: value,
                onChanged: onChanged,
                title: _content(title),
                subtitle: _content(n['subtitle']),
                secondary: _icon(n['icon']),
                contentPadding: pluginInsets(n['padding']),
              );
      case 'checkbox':
        final value = _value(n, false) == true;
        final onChanged = n['enabled'] == false ? null : (bool? next) => _change(n, next == true);
        final title = n['label'] ?? n['title'];
        return title == null
            ? Align(alignment: Alignment.centerLeft, child: Checkbox(value: value, onChanged: onChanged))
            : CheckboxListTile(
                value: value,
                onChanged: onChanged,
                title: _content(title),
                subtitle: _content(n['subtitle']),
                secondary: _icon(n['icon']),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: pluginInsets(n['padding']),
              );
      case 'radio':
      case 'radioGroup':
        final value = _value(n);
        return RadioGroup<Object?>(
          groupValue: value,
          onChanged: (next) => _change(n, next),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (n['label'] != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text('${n['label']}', style: Theme.of(context).textTheme.labelLarge),
                ),
              for (final option in _options(n['options']))
                RadioListTile<Object?>(
                  value: option.value,
                  title: Text(option.label),
                  secondary: _icon(option.icon),
                  enabled: n['enabled'] != false,
                ),
            ],
          ),
        );
      case 'slider':
        return _slider(n);
      case 'rangeSlider':
        final min = _double(n['min']) ?? 0;
        final max = _double(n['max']) ?? 1;
        final raw = _value(n, [min, max]);
        final values = raw is List && raw.length == 2
            ? RangeValues(
                (_double(raw[0]) ?? min).clamp(min, max),
                (_double(raw[1]) ?? max).clamp(min, max),
              )
            : RangeValues(min, max);
        final decimals = _int(n['decimals']) ?? 0;
        return _labeled(
          n,
          RangeSlider(
            values: values,
            min: min,
            max: max,
            divisions: _int(n['divisions']),
            labels: RangeLabels(values.start.toStringAsFixed(decimals), values.end.toStringAsFixed(decimals)),
            onChanged: n['enabled'] == false ? null : (next) => _change(n, [next.start, next.end], debounce: true),
          ),
          trailing: n['showValue'] == true
              ? '${values.start.toStringAsFixed(decimals)}–${values.end.toStringAsFixed(decimals)}${n['unit'] ?? ''}'
              : null,
        );
      case 'textField':
        return _textField(n);
      case 'dropdown':
        final value = _value(n);
        final options = _options(n['options']);
        return DropdownButtonFormField<Object?>(
          key: ValueKey('dropdown-${n['id']}-${jsonHash(value)}'),
          initialValue: options.any((option) => option.value == value) ? value : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: n['label'] as String?,
            hintText: n['hint'] as String?,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final option in options)
              DropdownMenuItem<Object?>(
                value: option.value,
                child: Row(
                  children: [
                    if (option.icon != null) ...[_icon(option.icon)!, const SizedBox(width: 8)],
                    Flexible(child: Text(option.label, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
          ],
          onChanged: n['enabled'] == false ? null : (next) => _change(n, next),
        );
      case 'segmented':
        final multi = n['multi'] == true;
        final raw = _value(n);
        final selected = multi ? {...(raw is List ? raw : const [])} : {raw};
        final options = _options(n['options']);
        return SegmentedButton<Object?>(
          multiSelectionEnabled: multi,
          emptySelectionAllowed: multi,
          showSelectedIcon: n['showSelectedIcon'] == true,
          segments: [
            for (final option in options)
              ButtonSegment<Object?>(value: option.value, label: Text(option.label), icon: _icon(option.icon)),
          ],
          selected: selected.where((value) => options.any((option) => option.value == value)).toSet(),
          onSelectionChanged: n['enabled'] == false
              ? null
              : (next) => _change(n, multi ? next.toList() : (next.isEmpty ? null : next.first)),
        );
      case 'chip':
        final label = Text('${n['label'] ?? ''}');
        final avatar = _icon(n['icon']);
        if (n['id'] != null && (n.containsKey('value') || n['toggle'] == true)) {
          return FilterChip(
            label: label,
            avatar: avatar,
            selected: _value(n, false) == true,
            onSelected: n['enabled'] == false ? null : (next) => _change(n, next),
          );
        }
        final action = n['action'];
        return action == null
            ? Chip(label: label, avatar: avatar)
            : ActionChip(label: label, avatar: avatar, onPressed: () => unawaited(_run(action, id: n['id'] as String?)));
      case 'choiceChips':
        final value = _value(n);
        return Wrap(
          spacing: _double(n['spacing']) ?? 8,
          runSpacing: 4,
          children: [
            for (final option in _options(n['options']))
              ChoiceChip(
                label: Text(option.label),
                avatar: _icon(option.icon),
                selected: option.value == value,
                onSelected: n['enabled'] == false
                    ? null
                    : (selected) => _change(n, selected ? option.value : (n['required'] == true ? value : null)),
              ),
          ],
        );
      case 'filterChips':
        final raw = _value(n);
        final selected = raw is List ? raw : const [];
        return Wrap(
          spacing: _double(n['spacing']) ?? 8,
          runSpacing: 4,
          children: [
            for (final option in _options(n['options']))
              FilterChip(
                label: Text(option.label),
                avatar: _icon(option.icon),
                selected: selected.contains(option.value),
                onSelected: n['enabled'] == false
                    ? null
                    : (next) => _change(n, [
                        for (final item in selected)
                          if (item != option.value) item,
                        if (next) option.value,
                      ]),
              ),
          ],
        );
      case 'colorPicker':
        return _colorPicker(n);
      case 'datePicker':
        return _datePicker(n);
      case 'expansionTile':
        return _expansion(
          n,
          title: _content(n['title']) ?? const SizedBox.shrink(),
          subtitle: _content(n['subtitle']),
          leading: _icon(n['leading'] ?? n['icon']),
          children: _kids(n),
        );
      case 'tabs':
        return _tabs(n);
      case 'gesture':
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: n['onTap'] == null && n['action'] == null
              ? null
              : () => unawaited(_run(n['onTap'] ?? n['action'], id: n['id'] as String?)),
          onDoubleTap: n['onDoubleTap'] == null
              ? null
              : () => unawaited(_run(n['onDoubleTap'], event: 'doubleTap', id: n['id'] as String?)),
          onLongPress: n['onLongPress'] == null
              ? null
              : () => unawaited(_run(n['onLongPress'], event: 'longPress', id: n['id'] as String?)),
          child: _child(n),
        );
      case 'regionEditor':
        return _regionEditor(n);
      case 'canvas':
        return _canvas(n);
      default:
        return _NodeError(type: type, error: 'unknown node type');
    }
  }

  Widget _section(Map<String, dynamic> n) {
    final title = n['title'];
    final children = _kids(n);
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: _double(n['spacing']) ?? 0,
      children: children,
    );
    if (n['collapsible'] == true) {
      return _expansion(
        n,
        title: _content(title, style: Theme.of(context).textTheme.titleSmall) ?? const SizedBox.shrink(),
        subtitle: _content(n['subtitle']),
        leading: _icon(n['icon']),
        children: [body],
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: pluginInsets(n['padding']) ?? const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  if (n['icon'] != null) ...[_icon(n['icon'], color: scheme.primary, size: 18)!, const SizedBox(width: 8)],
                  Expanded(
                    child: _content(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.primary),
                    )!,
                  ),
                ],
              ),
            ),
          if (n['subtitle'] != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: _content(n['subtitle'], style: Theme.of(context).textTheme.bodySmall),
            ),
          body,
        ],
      ),
    );
  }

  Widget _expansion(
    Map<String, dynamic> n, {
    required Widget title,
    Widget? subtitle,
    Widget? leading,
    required List<Widget> children,
  }) {
    final id = n['id'] as String?;
    final expanded = id != null && _values.containsKey('$id.expanded')
        ? _values['$id.expanded'] == true
        : n['expanded'] == true || n['initiallyExpanded'] == true;
    return ExpansionTile(
      key: PageStorageKey('plugin-expansion-${widget.plugin}-${id ?? title.hashCode}'),
      title: title,
      subtitle: subtitle,
      leading: leading,
      initiallyExpanded: expanded,
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      childrenPadding: pluginInsets(n['childrenPadding']) ?? EdgeInsets.zero,
      onExpansionChanged: (open) {
        if (id != null) {
          _values['$id.expanded'] = open;
        }
        if (n['onChange'] != null) {
          unawaited(_send('expand', id: id, value: open, action: _actionOf(n['onChange'] == true ? null : n['onChange'])));
        }
      },
      children: children,
    );
  }

  Widget _tabs(Map<String, dynamic> n) {
    final tabs = [for (final tab in (n['tabs'] is List ? n['tabs'] as List : const []).whereType<Map>()) tab];
    if (tabs.isEmpty) {
      return const SizedBox.shrink();
    }
    final index = (_int(_value(n, 0)) ?? 0).clamp(0, tabs.length - 1);
    return DefaultTabController(
      key: ValueKey('tabs-${n['id']}-${tabs.length}'),
      length: tabs.length,
      initialIndex: index,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            isScrollable: tabs.length > 3,
            onTap: (next) => _change(n, next),
            tabs: [
              for (final tab in tabs)
                Tab(text: tab['label'] as String?, icon: _icon(tab['icon'])),
            ],
          ),
          const SizedBox(height: 8),
          _build(tabs[index]['child']),
        ],
      ),
    );
  }

  Widget _button(Map<String, dynamic> n) {
    final label = Text('${n['label'] ?? n['text'] ?? ''}');
    final icon = _icon(n['icon']);
    final onPressed = n['enabled'] == false ? null : () => unawaited(_run(n['action'], id: n['id'] as String?));
    final destructive = n['destructive'] == true;
    final style = destructive
        ? FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          )
        : null;
    return switch (n['style'] ?? n['variant']) {
      'tonal' =>
        icon == null
            ? FilledButton.tonal(onPressed: onPressed, child: label)
            : FilledButton.tonalIcon(onPressed: onPressed, icon: icon, label: label),
      'outlined' =>
        icon == null
            ? OutlinedButton(onPressed: onPressed, child: label)
            : OutlinedButton.icon(onPressed: onPressed, icon: icon, label: label),
      'text' =>
        icon == null
            ? TextButton(onPressed: onPressed, child: label)
            : TextButton.icon(onPressed: onPressed, icon: icon, label: label),
      'elevated' =>
        icon == null
            ? ElevatedButton(onPressed: onPressed, child: label)
            : ElevatedButton.icon(onPressed: onPressed, icon: icon, label: label),
      _ =>
        icon == null
            ? FilledButton(onPressed: onPressed, style: style, child: label)
            : FilledButton.icon(onPressed: onPressed, style: style, icon: icon, label: label),
    };
  }

  Widget _labeled(Map<String, dynamic> n, Widget input, {String? trailing}) {
    final label = n['label'];
    if (label == null && trailing == null && n['icon'] == null) {
      return input;
    }
    final theme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              if (n['icon'] != null) ...[_icon(n['icon'], size: 18)!, const SizedBox(width: 8)],
              Expanded(child: Text('${label ?? ''}', style: theme.bodyMedium)),
              if (trailing != null) Text(trailing, style: theme.labelLarge),
            ],
          ),
        ),
        input,
        if (n['subtitle'] != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('${n['subtitle']}', style: theme.bodySmall),
          ),
      ],
    );
  }

  Widget _slider(Map<String, dynamic> n) {
    final min = _double(n['min']) ?? 0;
    final max = _double(n['max']) ?? 1;
    final value = (_double(_value(n, min)) ?? min).clamp(min, max);
    final decimals = _int(n['decimals']) ?? (n['divisions'] != null && (max - min) >= (_int(n['divisions']) ?? 1) ? 0 : 2);
    final text = '${value.toStringAsFixed(decimals)}${n['unit'] ?? ''}';
    return _labeled(
      n,
      Slider(
        value: value,
        min: min,
        max: max,
        divisions: _int(n['divisions']),
        label: text,
        onChanged: n['enabled'] == false ? null : (next) => _change(n, next, debounce: true),
        onChangeEnd: n['onChangeEnd'] == null
            ? null
            : (next) => unawaited(_run(n['onChangeEnd'], event: 'changeEnd', id: n['id'] as String?, value: next)),
      ),
      trailing: n['showValue'] == false ? null : text,
    );
  }

  Widget _textField(Map<String, dynamic> n) {
    final id = '${n['id'] ?? 'text-${n.hashCode}'}';
    final value = _value(n);
    final controller = _texts.putIfAbsent(id, () => TextEditingController(text: value == null ? '' : '$value'));
    final multiline = n['multiline'] == true;
    final keyboard = switch (n['keyboard']) {
      'number' => const TextInputType.numberWithOptions(decimal: true, signed: true),
      'integer' => TextInputType.number,
      'email' => TextInputType.emailAddress,
      'url' => TextInputType.url,
      'phone' => TextInputType.phone,
      _ => multiline ? TextInputType.multiline : TextInputType.text,
    };
    Object? parse(String text) => n['keyboard'] == 'number' || n['keyboard'] == 'integer'
        ? (num.tryParse(text) ?? (text.isEmpty ? null : text))
        : text;
    return TextField(
      controller: controller,
      enabled: n['enabled'] != false,
      obscureText: n['obscure'] == true,
      keyboardType: keyboard,
      maxLines: multiline ? (_int(n['maxLines'])) : 1,
      minLines: multiline ? (_int(n['minLines']) ?? 3) : null,
      maxLength: _int(n['maxLength']),
      textInputAction: multiline ? TextInputAction.newline : TextInputAction.done,
      decoration: InputDecoration(
        labelText: n['label'] as String?,
        hintText: n['hint'] as String?,
        helperText: n['helper'] as String?,
        errorText: n['error'] as String?,
        prefixIcon: _icon(n['prefixIcon'] ?? n['icon']),
        suffixText: n['suffix'] as String?,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (text) => _change(n, parse(text), debounce: true),
      onSubmitted: (text) {
        _values[id] = parse(text);
        if (n['onSubmit'] != null) {
          unawaited(_run(n['onSubmit'], event: 'submit', id: id, value: parse(text)));
        }
      },
    );
  }

  Widget _colorPicker(Map<String, dynamic> n) {
    final value = _value(n);
    final color = Color(parsePluginColor(value) ?? 0xFF2196F3);
    final alpha = n['alpha'] == true;
    final presets = n['presets'] is List
        ? [
            for (final preset in n['presets'] as List)
              if (parsePluginColor(preset) != null) Color(parsePluginColor(preset)!),
          ]
        : pluginDefaultColorPresets;
    if (n['inline'] == true) {
      return _labeled(
        n,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: PluginColorEditor(
            value: color,
            alpha: alpha,
            presets: presets,
            onChanged: (next) => _change(n, pluginColorHex(next), debounce: true),
          ),
        ),
      );
    }
    return ListTile(
      title: Text('${n['label'] ?? 'Color'}'),
      subtitle: Text(n['subtitle'] as String? ?? pluginColorHex(color)),
      leading: _icon(n['icon']),
      trailing: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
      ),
      enabled: n['enabled'] != false,
      onTap: () async {
        final picked = await showPluginColorPicker(
          context,
          initial: color,
          title: n['label'] as String?,
          alpha: alpha,
          presets: presets,
        );
        if (picked != null && mounted) {
          _change(n, pluginColorHex(picked));
        }
      },
    );
  }

  Widget _datePicker(Map<String, dynamic> n) {
    final value = _value(n);
    final date = value is String ? DateTime.tryParse(value) : null;
    final withTime = n['time'] == true;
    final first = n['firstDate'] is String ? DateTime.tryParse(n['firstDate'] as String) : null;
    final last = n['lastDate'] is String ? DateTime.tryParse(n['lastDate'] as String) : null;
    final label = date == null
        ? (n['hint'] as String? ?? 'Not set')
        : (withTime ? date.toLocal().toString().substring(0, 16) : date.toLocal().toString().substring(0, 10));
    return ListTile(
      title: Text('${n['label'] ?? 'Date'}'),
      subtitle: Text(label),
      leading: _icon(n['icon']) ?? const Icon(Icons.calendar_today_outlined),
      enabled: n['enabled'] != false,
      trailing: date != null && n['clearable'] == true
          ? IconButton(icon: const Icon(Icons.clear), onPressed: () => _change(n, null))
          : null,
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: date ?? now,
          firstDate: first ?? DateTime(1900),
          lastDate: last ?? DateTime(now.year + 50),
        );
        if (picked == null || !mounted) {
          return;
        }
        var result = picked;
        if (withTime) {
          final time = await showTimePicker(
            context: context,
            initialTime: TimeOfDay.fromDateTime(date ?? now),
          );
          if (!mounted) {
            return;
          }
          if (time != null) {
            result = DateTime(picked.year, picked.month, picked.day, time.hour, time.minute);
          }
        }
        _change(n, withTime ? result.toIso8601String() : result.toIso8601String().substring(0, 10));
      },
    );
  }

  Widget _image(Map<String, dynamic> n) {
    final fit = _fit(n['fit'], BoxFit.cover);
    final width = _double(n['width']);
    final height = _double(n['height']);
    final radius = _double(n['radius']);
    Widget error(BuildContext context, Object error, StackTrace? stack) => SizedBox(
      width: width,
      height: height,
      child: const Center(child: Icon(Icons.broken_image_outlined)),
    );
    final assetId = n['assetId'];
    Widget image;
    if (assetId is String) {
      return _assetImage(n, full: n['full'] == true);
    }
    final file = _resolveFile(n);
    final url = n['url'];
    final base64 = n['base64'];
    if (file != null) {
      final version = n['version'] ?? n['revision'];
      image = Image.file(
        File(file),
        key: version == null ? null : ValueKey('$file#$version'),
        fit: fit,
        width: width,
        height: height,
        gaplessPlayback: true,
        errorBuilder: error,
      );
      if (version != null) {
        unawaited(FileImage(File(file)).evict());
      }
    } else if (url is String) {
      image = Image.network(url, fit: fit, width: width, height: height, errorBuilder: error);
    } else if (base64 is String) {
      image = Image.memory(base64Decode(base64), fit: fit, width: width, height: height, errorBuilder: error);
    } else {
      return const SizedBox.shrink();
    }
    return radius == null ? image : ClipRRect(borderRadius: BorderRadius.all(Radius.circular(radius)), child: image);
  }

  Widget _assetImage(Map<String, dynamic> n, {required bool full}) {
    final assetId = '${n['assetId'] ?? ''}';
    final width = _double(n['width']);
    final height = _double(n['height']) ?? (full ? null : _double(n['size']));
    final fit = _fit(n['fit'], full ? BoxFit.contain : BoxFit.cover);
    final radius = _double(n['radius']);
    final child = FutureBuilder<BaseAsset?>(
      future: _asset(assetId),
      builder: (context, snapshot) {
        final asset = snapshot.data;
        final provider = asset == null
            ? null
            : (full ? getFullImageProvider(asset) : getThumbnailImageProvider(asset));
        if (provider == null) {
          return ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: snapshot.connectionState == ConnectionState.done
                ? const Center(child: Icon(Icons.image_not_supported_outlined))
                : null,
          );
        }
        return Image(image: provider, fit: fit, gaplessPlayback: true);
      },
    );
    final sized = SizedBox(width: width ?? _double(n['size']), height: height, child: child);
    return radius == null ? sized : ClipRRect(borderRadius: BorderRadius.all(Radius.circular(radius)), child: sized);
  }

  Widget _regionEditor(Map<String, dynamic> n) {
    final raw = _value(n, const []);
    final id = n['id'] as String?;
    final timeKey = id == null ? null : '$id.timeMs';
    final shapes = n['shapes'] ?? n['allowShapes'];
    return PluginRegionEditor(
      key: ValueKey('region-${widget.plugin}-$id'),
      kernel: _kernel,
      plugin: widget.plugin,
      pluginsRoot: _root,
      assetId: n['assetId'] as String?,
      file: n['file'] as String?,
      timeMs: _int(timeKey != null && _values.containsKey(timeKey) ? _values[timeKey] : n['timeMs']),
      durationMs: _int(n['durationMs']),
      scrubber: n['scrubber'] != false,
      value: [
        for (final region in (raw is List ? raw : const []).whereType<Map>()) Map<String, dynamic>.from(region),
      ],
      shapes: shapes is List ? [for (final shape in shapes) '$shape'] : const ['rect', 'ellipse'],
      maxShapes: _int(n['maxShapes']),
      color: pluginColor(context, n['color']),
      aspectRatio: _double(n['aspectRatio']),
      onChanged: (regions) => _change(n, regions),
      onSeek: (timeMs) {
        if (timeKey != null) {
          _values[timeKey] = timeMs;
        }
        if (n['onSeek'] != null || n['onChange'] != null) {
          unawaited(_send('seek', id: id, value: timeMs, action: _actionOf(n['onSeek'] ?? (n['onChange'] == true ? null : n['onChange']))));
        }
      },
    );
  }

  Widget _canvas(Map<String, dynamic> n) {
    final raw = _value(n, const {});
    final modes = n['modes'];
    return PluginCanvasEditor(
      key: ValueKey('canvas-${widget.plugin}-${n['id']}'),
      kernel: _kernel,
      plugin: widget.plugin,
      pluginsRoot: _root,
      value: raw is Map ? Map<String, dynamic>.from(raw) : const {},
      mode: '${n['mode'] ?? 'stroke'}',
      modes: modes is List ? [for (final mode in modes) '$mode'] : ['${n['mode'] ?? 'stroke'}'],
      color: pluginColor(context, n['color']) ?? Theme.of(context).colorScheme.primary,
      strokeWidth: _double(n['strokeWidth']) ?? 4,
      aspectRatio: _double(n['aspectRatio']),
      background: pluginColor(context, n['background']),
      assetId: n['assetId'] as String?,
      file: n['file'] as String?,
      timeMs: _int(n['timeMs']),
      onChanged: (value) => _change(n, value),
    );
  }

  bool _scrollsItself(Map<String, dynamic>? tree) => const {'list', 'grid', 'scroll'}.contains(tree?['type']);

  @override
  Widget build(BuildContext context) {
    _root = ref.watch(pluginFilesRootProvider).valueOrNull;
    final tree = _surface.tree;
    Widget body;
    if (tree == null) {
      body = _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$_error', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.tonal(onPressed: () => unawaited(_load()), child: const Text('Retry')),
                  ],
                ),
              ),
            )
          : (_loading ? const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())) : const SizedBox.shrink());
    } else {
      body = _build(tree);
      if (widget.scrollable && !_scrollsItself(tree)) {
        body = SingleChildScrollView(padding: widget.padding ?? const EdgeInsets.symmetric(vertical: 8), child: body);
      } else if (widget.padding != null) {
        body = Padding(padding: widget.padding!, child: body);
      }
    }
    if (_busy > 0) {
      body = Stack(
        children: [
          body,
          const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 2)),
        ],
      );
    }
    if (!widget.pageChrome) {
      return body;
    }
    final fab = _fab;
    return Scaffold(
      appBar: AppBar(
        title: Text(_title ?? widget.title ?? widget.plugin),
        actions: [for (final action in _appBarActions) _build(action)],
      ),
      floatingActionButton: fab == null ? null : _build(fab),
      body: SafeArea(top: false, child: body),
    );
  }
}

class _NodeError extends StatelessWidget {
  final String type;
  final Object error;

  const _NodeError({required this.type, required this.error});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(4),
    child: Text(
      '[$type] $error',
      style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
    ),
  );
}

// -------------------------------------------------------------------------------------------------------------------
// Pages, dialogs, sheets
// -------------------------------------------------------------------------------------------------------------------

/// A JSON UI page (`openUiPage`, settings pages, slot items with `uiMethod`). Nested pages push more of these;
/// `back` / `closePage` / a `close` response pops it with a result.
class PluginUiPage extends StatelessWidget {
  final String plugin;
  final String? title;
  final String? method;
  final String? page;
  final Map<String, dynamic>? ui;
  final Map<String, dynamic> params;
  final Map<String, dynamic> eventContext;
  final String? surface;

  const PluginUiPage({
    super.key,
    required this.plugin,
    this.title,
    this.method,
    this.page,
    this.ui,
    this.params = const {},
    this.eventContext = const {},
    this.surface,
  });

  @override
  Widget build(BuildContext context) => PluginUiView(
    plugin: plugin,
    title: title,
    method: method,
    page: page,
    ui: ui,
    params: params,
    eventContext: eventContext,
    surface: surface ?? 'page:${page ?? method ?? title ?? 'ui'}',
    scrollable: true,
    pageChrome: true,
    onClose: (result) => unawaited(Navigator.of(context).maybePop(result)),
  );
}

/// Opens a JSON UI page; completes with its close result when it is popped.
Future<Object?> openPluginUiPage(
  StackRouter router, {
  required String plugin,
  String? title,
  String? method,
  String? page,
  Map<String, dynamic>? ui,
  Map<String, dynamic> params = const {},
  Map<String, dynamic> eventContext = const {},
  String? surface,
}) => router.pushWidget<Object?>(
  PluginUiPage(
    plugin: plugin,
    title: title,
    method: method,
    page: page,
    ui: ui,
    params: params,
    eventContext: eventContext,
    surface: surface,
  ),
);

/// Buttons of `dialog` / `sheet` commands: `[{ "label", "value"?, "style"?: "filled" | "text" | "destructive" }]`.
List<({String label, Object? value, String? style})> _dialogButtons(Object? value) => [
  for (final button in value is List ? value : const [])
    button is Map
        ? (label: '${button['label'] ?? button['value']}', value: button['value'] ?? button['label'], style: button['style'] as String?)
        : (label: '$button', value: button, style: null),
];

/// Result of `dialog` / `sheet`: `{ "value": chosen button value or close result, "state": { inputs },
/// "dismissed": true when closed without a choice }`.
Map<String, dynamic> _dialogResult(Object? value, PluginUiController controller, {bool dismissed = false}) => {
  'value': value,
  'state': controller.state,
  'dismissed': dismissed,
};

/// Shows a JSON UI dialog (`dialog` command).
Future<Map<String, dynamic>> showPluginUiDialog(
  BuildContext context, {
  required String plugin,
  String? title,
  Map<String, dynamic>? ui,
  String? method,
  String? page,
  Map<String, dynamic> params = const {},
  String? surface,
  Object? buttons,
  bool dismissible = true,
}) async {
  final controller = PluginUiController();
  final options = _dialogButtons(buttons);
  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: dismissible,
    builder: (dialogContext) => AlertDialog(
      title: title == null ? null : Text(title),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: PluginUiView(
          plugin: plugin,
          ui: ui,
          method: method,
          page: page,
          params: params,
          surface: surface ?? 'dialog:${page ?? method ?? title ?? 'ui'}',
          controller: controller,
          scrollable: true,
          padding: EdgeInsets.zero,
          onClose: (value) => Navigator.of(dialogContext).pop(_dialogResult(value, controller)),
        ),
      ),
      actions: [
        for (final option in options)
          switch (option.style) {
            'filled' => FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(_dialogResult(option.value, controller)),
              child: Text(option.label),
            ),
            'destructive' => FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
                foregroundColor: Theme.of(dialogContext).colorScheme.onError,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(_dialogResult(option.value, controller)),
              child: Text(option.label),
            ),
            _ => TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(_dialogResult(option.value, controller)),
              child: Text(option.label),
            ),
          },
      ],
    ),
  );
  return result ?? _dialogResult(null, controller, dismissed: true);
}

/// Shows a JSON UI bottom sheet (`sheet` command, and plugin responses carrying `ui`).
Future<Map<String, dynamic>> showPluginUiSheet(
  BuildContext context, {
  required String plugin,
  String? title,
  Map<String, dynamic>? ui,
  String? method,
  String? page,
  Map<String, dynamic> params = const {},
  String? surface,
  Object? buttons,
  bool dismissible = true,
}) async {
  final controller = PluginUiController();
  final options = _dialogButtons(buttons);
  final result = await showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    builder: (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.9),
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(title, style: Theme.of(sheetContext).textTheme.titleLarge),
              ),
            Flexible(
              child: PluginUiView(
                plugin: plugin,
                ui: ui,
                method: method,
                page: page,
                params: params,
                surface: surface ?? 'sheet:${page ?? method ?? title ?? 'ui'}',
                controller: controller,
                scrollable: true,
                onClose: (value) => Navigator.of(sheetContext).pop(_dialogResult(value, controller)),
              ),
            ),
            if (options.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  spacing: 8,
                  children: [
                    for (final option in options)
                      option.style == 'filled'
                          ? FilledButton(
                              onPressed: () => Navigator.of(sheetContext).pop(_dialogResult(option.value, controller)),
                              child: Text(option.label),
                            )
                          : TextButton(
                              onPressed: () => Navigator.of(sheetContext).pop(_dialogResult(option.value, controller)),
                              child: Text(option.label),
                            ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
  return result ?? _dialogResult(null, controller, dismissed: true);
}

/// Copies text to the clipboard (`copy` command).
Future<void> pluginCopy(String text) => Clipboard.setData(ClipboardData(text: text));
