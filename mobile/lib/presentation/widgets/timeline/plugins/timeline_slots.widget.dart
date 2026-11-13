import 'package:flutter/material.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';

/// The page a timeline belongs to (`mainTimeline`, `archive`, ...), for the slot contexts and hook arguments of
/// its tiles and headers.
class TimelinePageScope extends InheritedWidget {
  final String page;

  const TimelinePageScope({super.key, required this.page, required super.child});

  static String of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TimelinePageScope>()?.page ?? TimelinePages.timeline;

  @override
  bool updateShouldNotify(TimelinePageScope oldWidget) => page != oldWidget.page;
}

/// The content plugins put into [slots] (in order), or null when none of them has any. [context] is only built when
/// a slot has content.
Widget? timelineSlotContent(TimelinePluginBridge bridge, List<String> slots, Map<String, dynamic> Function() context) {
  if (!slots.any(bridge.hasContent)) {
    return null;
  }
  final built = context();
  final contents = [
    for (final slot in slots)
      if (bridge.hasContent(slot)) ?bridge.content(slot, built),
  ];
  return switch (contents.length) {
    0 => null,
    1 => contents.single,
    _ => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: contents),
  };
}
