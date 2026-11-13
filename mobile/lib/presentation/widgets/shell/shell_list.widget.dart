import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_ids.dart';

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
  const ShellItem(this.id, this.child);

  final String id;
  final Widget child;
}

/// Builds a list of built-in items that plugins can extend through [slot].
///
/// This is the single place where the shell's built-in lists (settings sub pages, the profile dialog, app bar
/// actions, the backup page, ...) meet the plugin kernel: plugins hide, reorder or wrap the built-in items by id and
/// add their own items of the slot at their `order`. [slotContext] is the slot context plugins match with `when`.
/// [builder] receives the final list of widgets.
class ShellList extends StatelessWidget {
  const ShellList({
    super.key,
    required this.slot,
    required this.items,
    required this.builder,
    this.slotContext = const {},
  });

  final String slot;
  final List<ShellItem> items;
  final Map<String, dynamic> slotContext;
  final Widget Function(BuildContext context, List<Widget> children) builder;

  @override
  Widget build(BuildContext context) => builder(context, [for (final item in items) item.child]);
}
