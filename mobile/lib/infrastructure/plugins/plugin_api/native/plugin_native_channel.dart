import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// A natively implemented host function, as reported by the native runtime.
class PluginNativeFunction {
  final String name;

  /// The plugin that registered it, or null for built-ins.
  final String? owner;
  final String? doc;
  final bool isAsync;

  const PluginNativeFunction({required this.name, this.owner, this.doc, this.isAsync = false});

  factory PluginNativeFunction.fromMap(Map<dynamic, dynamic> map) => PluginNativeFunction(
    name: map['name'] as String,
    owner: map['owner'] as String?,
    doc: map['doc'] as String?,
    isAsync: map['async'] == true,
  );
}

/// What the native plugin runtime offers (`native.info`).
class PluginNativeInfo {
  final bool available;
  final int apiVersion;
  final Set<String> features;
  final List<PluginNativeFunction> functions;

  /// Plugins loaded natively in this process.
  final List<String> plugins;

  const PluginNativeInfo({
    required this.available,
    required this.apiVersion,
    required this.features,
    required this.functions,
    required this.plugins,
  });

  static const unavailable = PluginNativeInfo(
    available: false,
    apiVersion: 0,
    features: <String>{},
    functions: <PluginNativeFunction>[],
    plugins: <String>[],
  );

  factory PluginNativeInfo.fromMap(Map<dynamic, dynamic> map) => PluginNativeInfo(
    available: true,
    apiVersion: (map['apiVersion'] as num?)?.toInt() ?? 0,
    features: {for (final feature in map['features'] as List? ?? const []) feature as String},
    functions: [
      for (final function in map['functions'] as List? ?? const [])
        if (function is Map) PluginNativeFunction.fromMap(function),
    ],
    plugins: [for (final plugin in map['plugins'] as List? ?? const []) plugin as String],
  );
}

/// A failed native host function call.
class PluginNativeException implements Exception {
  final int status;
  final String message;

  const PluginNativeException(this.status, this.message);

  @override
  String toString() => 'PluginNativeException($status): $message';
}

typedef PluginNativeEmitHandler = void Function(String event, Map<String, dynamic> data, String? plugin);
typedef PluginNativeCommandHandler = Future<Object?> Function(String plugin, Map<String, dynamic> command);
typedef PluginNativePerformHandler = Future<void> Function(String plugin, Map<String, dynamic> response);
typedef PluginNativeLogHandler =
    void Function(String? plugin, String level, String message, String? error, String? stack);

/// Dart side of the `immich/plugin_native` channel (Android only; a no-op elsewhere).
///
/// Native to Dart: `emit` (native events: activity, intent, notification, work, task, permission, plugin errors and
/// plugin-emitted events) to [onEmit]; `log` to [onLog] (default: the app log); `command` (a plugin command sent
/// while the app's plugin host was not running) to [onCommand]; `perform` (a plugin response to a native-initiated
/// call) to [onPerform]; `subscriptions` (event patterns native listeners want, see [forwardEvent]);
/// `contentHeight` (inline plugin view heights, see [contentHeight]).
class PluginNativeChannel {
  PluginNativeChannel._();

  static final PluginNativeChannel instance = PluginNativeChannel._();

  static const channel = MethodChannel('immich/plugin_native');

  final _log = Logger('PluginNative');
  final Map<int, ValueNotifier<double?>> _heights = {};
  Set<String> _patterns = const {};
  PluginNativeInfo _info = PluginNativeInfo.unavailable;

  PluginNativeEmitHandler? onEmit;
  PluginNativeCommandHandler? onCommand;
  PluginNativePerformHandler? onPerform;
  PluginNativeLogHandler? onLog;

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  PluginNativeInfo get info => _info;

  /// Event patterns native listeners subscribed to.
  Set<String> get nativeSubscriptions => _patterns;

  /// Starts receiving native messages; native events queued before this are delivered right after.
  Future<PluginNativeInfo> attach() async {
    if (!isSupported) {
      return _info = PluginNativeInfo.unavailable;
    }
    channel.setMethodCallHandler(_handle);
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('attach');
      return _info = result == null ? PluginNativeInfo.unavailable : PluginNativeInfo.fromMap(result);
    } on MissingPluginException {
      return _info = PluginNativeInfo.unavailable;
    }
  }

  Future<void> detach() async {
    if (!isSupported) {
      return;
    }
    channel.setMethodCallHandler(null);
    _info = PluginNativeInfo.unavailable;
    try {
      await channel.invokeMethod<void>('detach');
    } on MissingPluginException {
      return;
    }
  }

  Future<PluginNativeInfo> refreshInfo() async {
    if (!isSupported) {
      return PluginNativeInfo.unavailable;
    }
    final result = await channel.invokeMapMethod<String, dynamic>('info');
    return _info = result == null ? PluginNativeInfo.unavailable : PluginNativeInfo.fromMap(result);
  }

  /// Calls a natively implemented host function for [plugin]. Returns its response; throws [PluginNativeException].
  Future<Object?> callHost(String plugin, String name, List<dynamic> args) async {
    if (!isSupported) {
      throw const PluginNativeException(501, 'Native host functions are only available on Android');
    }
    final envelope = await channel.invokeMethod<String>('call', {
      'plugin': plugin,
      'name': name,
      'args': jsonEncode(args),
    });
    final decoded = envelope == null ? null : jsonDecode(envelope);
    if (decoded is Map && decoded['success'] == true) {
      return decoded['response'];
    }
    final status = decoded is Map ? (decoded['status'] as num?)?.toInt() ?? 500 : 500;
    final message = decoded is Map ? decoded['message'] as String? ?? 'Host function $name failed' : 'No response';
    throw PluginNativeException(status, message);
  }

  /// True when a native listener subscribed to [event].
  bool wantsEvent(String event) => _patterns.any((pattern) => _matches(pattern, event));

  /// Forwards an app event to native listeners when one subscribed to it. Events that came from native code (their
  /// data has `origin: native`) are not sent back.
  Future<void> forwardEvent(String event, Map<String, dynamic> data) async {
    if (!isSupported || data['origin'] == 'native' || !wantsEvent(event)) {
      return;
    }
    await channel.invokeMethod<void>('dispatchEvent', {'event': event, 'data': jsonEncode(data)});
  }

  /// Sends the app theme to native code (plugin views, notifications). See [themeToMap].
  Future<void> setTheme(Map<String, dynamic> theme) async {
    if (!isSupported) {
      return;
    }
    await channel.invokeMethod<void>('setTheme', {'theme': jsonEncode(theme)});
  }

  /// `{ dark, colors: { role: argb }, fontFamily, textScale }` for [setTheme].
  static Map<String, dynamic> themeToMap(ThemeData theme, {double textScale = 1.0}) {
    final scheme = theme.colorScheme;
    return {
      'dark': theme.brightness == Brightness.dark,
      'colors': {
        'primary': scheme.primary.toARGB32(),
        'onPrimary': scheme.onPrimary.toARGB32(),
        'primaryContainer': scheme.primaryContainer.toARGB32(),
        'onPrimaryContainer': scheme.onPrimaryContainer.toARGB32(),
        'secondary': scheme.secondary.toARGB32(),
        'onSecondary': scheme.onSecondary.toARGB32(),
        'secondaryContainer': scheme.secondaryContainer.toARGB32(),
        'onSecondaryContainer': scheme.onSecondaryContainer.toARGB32(),
        'tertiary': scheme.tertiary.toARGB32(),
        'onTertiary': scheme.onTertiary.toARGB32(),
        'error': scheme.error.toARGB32(),
        'onError': scheme.onError.toARGB32(),
        'surface': scheme.surface.toARGB32(),
        'onSurface': scheme.onSurface.toARGB32(),
        'onSurfaceVariant': scheme.onSurfaceVariant.toARGB32(),
        'surfaceContainerLowest': scheme.surfaceContainerLowest.toARGB32(),
        'surfaceContainerLow': scheme.surfaceContainerLow.toARGB32(),
        'surfaceContainer': scheme.surfaceContainer.toARGB32(),
        'surfaceContainerHigh': scheme.surfaceContainerHigh.toARGB32(),
        'surfaceContainerHighest': scheme.surfaceContainerHighest.toARGB32(),
        'outline': scheme.outline.toARGB32(),
        'outlineVariant': scheme.outlineVariant.toARGB32(),
        'inverseSurface': scheme.inverseSurface.toARGB32(),
        'onInverseSurface': scheme.onInverseSurface.toARGB32(),
        'inversePrimary': scheme.inversePrimary.toARGB32(),
        'scrim': scheme.scrim.toARGB32(),
        'shadow': scheme.shadow.toARGB32(),
      },
      'fontFamily': theme.textTheme.bodyMedium?.fontFamily,
      'textScale': textScale,
    };
  }

  /// The content height (logical pixels) the inline plugin view [viewId] reported, null until it reports one.
  ValueListenable<double?> contentHeight(int viewId) => _heights.putIfAbsent(viewId, () => ValueNotifier<double?>(null));

  /// Call when platform view [viewId] is disposed.
  void releaseContentHeight(int viewId) => _heights.remove(viewId)?.dispose();

  // ---- tasks: app-native progress notification -------------------------------------------------------------------

  /// Shows or updates the notification of task [id]. [progress] 0..1, null for indeterminate. A cancel button is
  /// shown when [cancellable]; tapping it emits `task.cancelled { id, plugin }`.
  Future<void> showTask({
    required String id,
    required String title,
    String? plugin,
    String? text,
    double? progress,
    bool cancellable = false,
  }) async {
    if (!isSupported) {
      return;
    }
    await channel.invokeMethod<void>('taskShow', {
      'id': id,
      'plugin': plugin,
      'title': title,
      'text': text,
      'progress': progress,
      'cancellable': cancellable,
    });
  }

  /// Removes the notification of task [id], or with [keep] leaves a dismissible final notification.
  Future<void> finishTask(String id, {String? title, String? text, bool success = true, bool keep = false}) async {
    if (!isSupported) {
      return;
    }
    await channel.invokeMethod<void>('taskFinish', {
      'id': id,
      'title': title,
      'text': text,
      'success': success,
      'keep': keep,
    });
  }

  Future<void> cancelTask(String id) async {
    if (!isSupported) {
      return;
    }
    await channel.invokeMethod<void>('taskCancel', {'id': id});
  }

  // ---- native to Dart --------------------------------------------------------------------------------------------

  Future<Object?> _handle(MethodCall call) async {
    final arguments = call.arguments;
    final args = arguments is Map ? Map<String, dynamic>.from(arguments) : const <String, dynamic>{};
    switch (call.method) {
      case 'emit':
        final event = args['event'] as String?;
        if (event != null) {
          onEmit?.call(event, _decodeMap(args['data']), args['plugin'] as String?);
        }
        return null;
      case 'log':
        _onLog(
          args['plugin'] as String?,
          args['level'] as String? ?? 'info',
          args['message'] as String? ?? '',
          args['error'] as String?,
          args['stack'] as String?,
        );
        return null;
      case 'command':
        final handler = onCommand;
        final plugin = args['plugin'] as String?;
        if (handler == null || plugin == null) {
          return null;
        }
        return handler(plugin, {'type': args['name'], ..._decodeMap(args['payload'])});
      case 'perform':
        final handler = onPerform;
        final plugin = args['plugin'] as String?;
        if (handler != null && plugin != null) {
          await handler(plugin, _decodeMap(args['response']));
        }
        return null;
      case 'subscriptions':
        _patterns = {for (final pattern in args['patterns'] as List? ?? const []) pattern as String};
        return null;
      case 'contentHeight':
        final viewId = (args['viewId'] as num?)?.toInt();
        final height = (args['height'] as num?)?.toDouble();
        if (viewId != null && height != null) {
          _heights.putIfAbsent(viewId, () => ValueNotifier<double?>(null)).value = height;
        }
        return null;
      default:
        throw MissingPluginException(call.method);
    }
  }

  void _onLog(String? plugin, String level, String message, String? error, String? stack) {
    final handler = onLog;
    if (handler != null) {
      handler(plugin, level, message, error, stack);
      return;
    }
    final logger = plugin == null ? _log : Logger('Plugin:$plugin');
    final record = error == null ? message : '$message\n$error';
    switch (level) {
      case 'severe':
      case 'error':
        logger.severe(record, null, stack == null ? null : StackTrace.fromString(stack));
      case 'warning':
        logger.warning(record);
      case 'fine':
      case 'debug':
        logger.fine(record);
      default:
        logger.info(record);
    }
  }

  static Map<String, dynamic> _decodeMap(Object? value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    if (value is! String || value.isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  static bool _matches(String pattern, String event) {
    if (pattern == '*' || pattern == event) {
      return true;
    }
    return pattern.endsWith('.*') && event.startsWith(pattern.substring(0, pattern.length - 1));
  }
}
