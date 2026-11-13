import 'package:immich_mobile/infrastructure/plugins/plugin_api/native/plugin_native_channel.dart';

/// Registers a host function with the plugin kernel (`PluginKernel.registerHost`).
typedef NativeHostRegistrar =
    void Function(String name, Future<Object?> Function(String plugin, List<dynamic> args) handler, {String? doc});

/// Registers every built-in natively implemented host function (`native.*`, `activity.*`, `intent.*`,
/// `permissions.*`, `notify.*`, `work.*`) with the kernel so Dart callers, JSON UI and introspection see them.
/// Native callers reach them without a Dart round trip. Functions plugins register natively are reachable through
/// `native.call`. Call after [PluginNativeChannel.attach].
void registerNativeHostFunctions(NativeHostRegistrar register, {PluginNativeChannel? channel}) {
  final native = channel ?? PluginNativeChannel.instance;
  for (final function in native.info.functions) {
    if (function.owner != null) {
      continue;
    }
    final name = function.name;
    register(name, (plugin, args) => native.callHost(plugin, name, args), doc: function.doc);
  }
}
