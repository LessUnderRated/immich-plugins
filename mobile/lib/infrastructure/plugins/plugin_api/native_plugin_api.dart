import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/native/native_host_functions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/native/plugin_native_channel.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:logging/logging.dart';

/// Plugin API of the **native** area: host functions the Android plugin host provides (lifecycle, intents,
/// permissions, notifications, background work, media, video frames), registered once the native bridge attaches.
void registerNativePluginApi(PluginKernel kernel, Ref ref) {
  if (!PluginNativeChannel.isSupported) {
    return;
  }
  unawaited(
    PluginNativeChannel.instance
        .attach()
        .then(
          (_) => registerNativeHostFunctions(
            (name, handler, {doc}) => kernel.registerHost(name, handler, doc: doc, area: 'native'),
          ),
        )
        .catchError((Object error, StackTrace stack) {
          Logger('NativePluginApi').warning('The native plugin bridge is not available', error, stack);
        }),
  );
}
