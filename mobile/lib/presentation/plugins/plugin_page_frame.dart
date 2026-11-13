import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/plugins/plugin_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_mobile/providers/timeline/timeline_plugins.provider.dart';

/// The generic slots every page gets (`PLUGINS.md`, "Slots"): `<page>.header` and `<page>.footer` (content above /
/// below the page), `<page>.fab` (content and buttons floating bottom right) and `<page>.body` (`replace` / `wrap` of
/// the whole page). Wrapped around every route by the router; costs nothing for pages no plugin targets.
///
/// Pages that serve some of these slots themselves (every timeline page, a few library pages) are skipped for those
/// slots so nothing shows twice. `<page>.empty` is served by the pages that have an empty state.
class PluginPageFrame extends ConsumerWidget {
  final String routeName;
  final Widget child;

  const PluginPageFrame({super.key, required this.routeName, required this.child});

  /// Generic slots a page already renders itself, by page prefix.
  static const _servedByPage = <String, Set<String>>{
    'folder': {PluginSlotSuffix.header},
    'downloadInfo': {PluginSlotSuffix.footer},
    'activities': {PluginSlotSuffix.footer},
  };

  static const _timelineSuffixes = {
    PluginSlotSuffix.header,
    PluginSlotSuffix.footer,
    PluginSlotSuffix.fab,
    PluginSlotSuffix.body,
  };

  bool _served(String prefix, String suffix) =>
      (TimelinePages.all.contains(prefix) && _timelineSuffixes.contains(suffix)) ||
      (_servedByPage[prefix]?.contains(suffix) ?? false);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bridge = ref.watch(timelinePluginBridgeProvider);
    final prefix = routeSlotPrefix(routeName);
    String? slotFor(String suffix) => _served(prefix, suffix) ? null : '$prefix$suffix';
    final slotContext = {'route': routeName, 'page': prefix};

    final headerSlot = slotFor(PluginSlotSuffix.header);
    final footerSlot = slotFor(PluginSlotSuffix.footer);
    final fabSlot = slotFor(PluginSlotSuffix.fab);
    final bodySlot = slotFor(PluginSlotSuffix.body);

    final header = headerSlot != null && bridge.hasContent(headerSlot) ? bridge.content(headerSlot, slotContext) : null;
    final footer = footerSlot != null && bridge.hasContent(footerSlot) ? bridge.content(footerSlot, slotContext) : null;
    final fabContent = fabSlot != null && bridge.hasContent(fabSlot) ? bridge.content(fabSlot, slotContext) : null;
    final fabButtons = fabSlot == null
        ? const <Widget>[]
        : [for (final b in bridge.buttons(fabSlot, slotContext)) b.item];
    final decorated = bodySlot != null && bridge.hasDecorations(bodySlot);

    if (header == null && footer == null && fabContent == null && fabButtons.isEmpty && !decorated) {
      return child;
    }

    Widget page = decorated ? bridge.decorate(bodySlot, slotContext, child) : child;
    if (header != null || footer != null) {
      page = Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header != null) SafeArea(bottom: false, child: header),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: header != null,
                removeBottom: footer != null,
                child: page,
              ),
            ),
            if (footer != null) SafeArea(top: false, child: footer),
          ],
        ),
      );
    }
    if (fabContent != null || fabButtons.isNotEmpty) {
      page = Stack(
        children: [
          Positioned.fill(child: page),
          Positioned(
            right: 16,
            bottom: 16 + MediaQuery.paddingOf(context).bottom,
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                spacing: 8,
                children: [?fabContent, ...fabButtons],
              ),
            ),
          ),
        ],
      );
    }
    return page;
  }
}
