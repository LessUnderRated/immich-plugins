import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';

/// What the timeline area renders from plugins. The default bridge renders nothing extra; the plugin kernel binds
/// its own implementation here.
final timelinePluginBridgeProvider = ChangeNotifierProvider<TimelinePluginBridge>((ref) => TimelinePluginBridge());
