import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/builtin_rules.dart';
import 'package:immich_mobile/presentation/actions/action_slots.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';
import 'package:immich_mobile/providers/timeline/timeline_plugins.provider.dart';

/// The route name of the page showing [context], or null outside a route page (dialogs on the root navigator,
/// pages pushed with `pushWidget`).
String? currentRouteName(BuildContext context) =>
    context.findAncestorWidgetOfExactType<RouteDataScope>()?.routeData.name;

/// The page slot `<page>.<suffix>` of the route showing [context] (see [pageSlot]); [fallback] outside a route page.
String routeSlotOf(BuildContext context, String suffix, {String fallback = 'page'}) {
  final route = currentRouteName(context);
  return route == null ? '$fallback.$suffix' : pageSlot(route, suffix);
}

/// A built-in item of a plugin-extensible list, with its stable id (`docs/plugins/shell.md`).
@immutable
class ShellItem {
  const ShellItem(String this.id, this.child);

  /// An item that keeps the id its widget already carries (a [BuiltinSlotItem] or action widget a page passed in),
  /// or has none (unnamed items stay where they are; `*` in an `order` rule places them).
  const ShellItem.passThrough(this.child) : id = null;

  final String? id;
  final Widget child;

  Widget get widget {
    final id = this.id;
    return id == null ? child : BuiltinSlotItem(id: id, child: child);
  }
}

/// How a [ShellList] presents plugin items of its slot.
enum ShellListKind {
  /// A row of buttons (app bar actions): plugin `button` and `toggle` items.
  buttons,

  /// An overflow menu: plugin `menuItem` items.
  menu,

  /// Tiles and blocks (settings items, dialog sections, page cards): plugin content (`section`, `view`) goes last.
  items,
}

/// Builds a list of built-in items that plugins can extend through [slot].
///
/// This is the single place where the shell's built-in lists (settings, the profile dialog, app bar actions, the
/// backup page, ...) meet the plugins. It uses the same rules and plugin items as the timeline area's bars
/// ([arrangeButtons], [arrangeMenuItems], [TimelinePluginBridge]): plugins hide, reorder and rename built-in items by
/// id and add their own items of the slot. [slotContext] is the context plugins match with `when`. [builder]
/// receives the final list of widgets. Without plugins it returns the built-ins as they are.
class ShellList extends ConsumerWidget {
  const ShellList({
    super.key,
    required this.slot,
    required this.items,
    required this.builder,
    this.slotContext = const {},
    this.kind = ShellListKind.items,
  });

  final String slot;
  final List<ShellItem> items;
  final Map<String, dynamic> slotContext;
  final ShellListKind kind;
  final Widget Function(BuildContext context, List<Widget> children) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final builtins = [for (final item in items) item.widget];
    final children = switch (kind) {
      ShellListKind.buttons => arrangeButtons(ref, slot, builtins, context: slotContext),
      ShellListKind.menu => arrangeMenuItems(ref, slot, builtins, context: slotContext),
      ShellListKind.items => _arrangeItems(ref, builtins),
    };
    return builder(context, children);
  }

  List<Widget> _arrangeItems(WidgetRef ref, List<Widget> builtins) {
    final bridge = ref.watch(timelinePluginBridgeProvider);
    final arranged = arrangeSlotItems<Widget>(builtins, slotItemId, rules: bridge.rules([slot]));
    if (!bridge.hasContent(slot)) {
      return arranged;
    }
    final content = bridge.content(slot, slotContext);
    return content == null ? arranged : [...arranged, content];
  }
}
