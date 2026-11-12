import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';

typedef HostFunctionHandler = Future<String> Function(String plugin, String name, String input);
typedef PluginEventHandler = Future<void> Function(String plugin, String name, String payload);

class PluginRuntime {
  static const _channel = MethodChannel('immich/dex_plugins');

  HostFunctionHandler? _hostHandler;
  PluginEventHandler? eventHandler;

  PluginRuntime() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  set hostHandler(HostFunctionHandler handler) => _hostHandler = handler;

  Future<Object?> _onNativeCall(MethodCall call) async {
    final args = Map<String, dynamic>.from(call.arguments as Map);
    switch (call.method) {
      case 'event':
        await eventHandler?.call(args['plugin'] as String, args['name'] as String, args['payload'] as String? ?? '{}');
        return null;
      case 'host':
        final handler = _hostHandler;
        if (handler == null) {
          return jsonEncode({'success': false, 'status': 503, 'message': 'Plugin host is not ready'});
        }
        return handler(args['plugin'] as String, args['name'] as String, args['input'] as String);
      default:
        throw MissingPluginException(call.method);
    }
  }

  Future<void> load(DevicePlugin plugin) =>
      _channel.invokeMethod('load', {'key': plugin.name, 'dexPath': plugin.codePath, 'entry': plugin.entry});

  Future<void> unload(String name) => _channel.invokeMethod('unload', {'key': name});

  Future<Map<String, dynamic>?> call(String plugin, String method, Map<String, dynamic> input) async {
    final output = await _channel.invokeMethod<String>('call', {
      'key': plugin,
      'method': method,
      'input': jsonEncode(input),
    });
    if (output == null || output.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(output);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }
}
