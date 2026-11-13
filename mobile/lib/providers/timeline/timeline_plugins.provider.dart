import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/plugins/kernel_timeline_bridge.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';
import 'package:immich_mobile/providers/plugin_kernel.provider.dart';

/// The kernel-backed bridge: plugin rules, items, content, decorations and tabs for every bar, menu and list.
final timelinePluginBridgeProvider = ChangeNotifierProvider<TimelinePluginBridge>(
  (ref) => KernelTimelinePluginBridge(ref.read(pluginKernelProvider)),
);
