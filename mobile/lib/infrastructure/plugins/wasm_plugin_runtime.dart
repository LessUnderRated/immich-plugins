import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';

typedef HostFunctionHandler = Future<String> Function(String plugin, String name, String input);

const deviceHostFunctions = [
  'searchAlbums',
  'createAlbum',
  'addAssetsToAlbum',
  'addAssetsToAlbums',
  'httpRequest',
  'bulkTagAssets',
  'getAssetEdits',
  'editAsset',
  'removeAssetEdits',
  'listAssets',
  'getAsset',
  'readImage',
  'writeImage',
  'readFile',
  'writeFile',
  'listFiles',
  'deleteFile',
  'getStorage',
  'setStorage',
];

class WasmPluginRuntime {
  static const _channel = MethodChannel('immich/wasm_plugins');
  static const _dexChannel = MethodChannel('immich/dex_plugins');

  final Map<String, DevicePluginRuntime> _runtimes = {};

  HostFunctionHandler? _hostHandler;

  WasmPluginRuntime() {
    _channel.setMethodCallHandler(_onNativeCall);
    _dexChannel.setMethodCallHandler(_onNativeCall);
  }

  set hostHandler(HostFunctionHandler handler) => _hostHandler = handler;

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method != 'host') {
      throw MissingPluginException(call.method);
    }
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final handler = _hostHandler;
    if (handler == null) {
      return jsonEncode({'success': false, 'status': 503, 'message': 'Plugin host is not ready'});
    }
    return handler(args['plugin'] as String, args['name'] as String, args['input'] as String);
  }

  MethodChannel _channelFor(String plugin) => _runtimes[plugin] == DevicePluginRuntime.dex ? _dexChannel : _channel;

  Future<void> load(DevicePlugin plugin) async {
    _runtimes[plugin.name] = plugin.runtime;
    await switch (plugin.runtime) {
      DevicePluginRuntime.wasm => _channel.invokeMethod('load', {
        'key': plugin.name,
        'wasmPath': plugin.codePath,
        'hostFunctions': deviceHostFunctions,
        'enableHostFunctions': true,
      }),
      DevicePluginRuntime.dex => _dexChannel.invokeMethod('load', {
        'key': plugin.name,
        'dexPath': plugin.codePath,
        'entry': plugin.entry,
      }),
    };
  }

  Future<void> unload(String name) async {
    await _channelFor(name).invokeMethod('unload', {'key': name});
    _runtimes.remove(name);
  }

  Future<Map<String, dynamic>?> call(String plugin, String method, Map<String, dynamic> input) async {
    final output = await _channelFor(
      plugin,
    ).invokeMethod<String>('call', {'key': plugin, 'method': method, 'input': jsonEncode(input)});
    if (output == null || output.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(output);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }
}
