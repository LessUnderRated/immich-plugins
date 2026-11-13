import 'package:flutter/material.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/builtin_rules.dart';
import 'package:immich_mobile/presentation/actions/action.dart';

/// A plugin tab of the bottom navigation.
class TimelinePluginTab {
  /// `plugin:<plugin>/<id>`.
  final String id;
  final String title;
  final IconData icon;
  final IconData? selectedIcon;

  /// Position among the tabs: built-in tab `i` has order `(i + 1) * 100`; default after every tab.
  final double order;

  /// The tab's page (JSON UI page or native view), built with the app's theme like a built-in tab.
  final WidgetBuilder builder;

  const TimelinePluginTab({
    required this.id,
    required this.title,
    required this.icon,
    required this.builder,
    this.selectedIcon,
    this.order = builtinRulesLast,
  });
}

/// Everything the timeline area asks the plugin kernel for.
///
/// This default answers "nothing": no rules, no plugin items, no decorations, no tabs, so every surface renders
/// exactly its built-in content at no cost. The kernel binding (phase B) subclasses it and notifies listeners when
/// plugin contributions change. All methods are synchronous and cheap; `has*` methods are checked before a call site
/// builds a slot context.
class TimelinePluginBridge extends ChangeNotifier {
  TimelinePluginBridge();

  /// Merged hide / order / rename rules of [slots], generic slot first.
  BuiltinItemRules rules(List<String> slots) => BuiltinItemRules.none;

  /// Plugin actions (`button`, `menuItem` contributions) of an action list slot (`selection.actions`,
  /// `viewer.topBar`, ...), as builders so every bar presents them like built-ins. Their `create` decides
  /// applicability (`when`) from the current assets.
  List<SlotExtraItem<ActionBuilder>> actions(String slot, {ActionSource source = ActionSource.timeline}) => const [];

  /// Plugin buttons and toggles of a button row slot (`<page>.appBar.actions`, `app.appBar.actions`).
  List<SlotExtraItem<Widget>> buttons(String slot, Map<String, dynamic> context) => const [];

  /// Plugin entries of an overflow menu slot (`<page>.appBar.menu`, `app.menu`).
  List<SlotExtraItem<Widget>> menuItems(String slot, Map<String, dynamic> context) => const [];

  /// Whether [slot] has content contributions (`section`, `view`, `panel`).
  bool hasContent(String slot) => false;

  /// The content of [slot] (JSON UI or native views, stacked in order), or null when it has none.
  Widget? content(String slot, Map<String, dynamic> context) => null;

  /// Whether [slot] has decorations (`badge`, `wrap`, `replace`).
  bool hasDecorations(String slot) => false;

  /// [child] decorated by the plugins of [slot]: replaced, wrapped and badged. Returns [child] when there are none.
  Widget decorate(String slot, Map<String, dynamic> context, Widget child) => child;

  /// Plugin tabs of the bottom navigation.
  List<TimelinePluginTab> get tabs => const [];

  /// Changes whenever the set of `timeline.query` hooks changes, so timelines rebuild their query.
  int get queryRevision => 0;
}

/// Marks a built-in widget of a bar or menu with its id, so plugin rules can hide, reorder and find it.
class BuiltinSlotItem extends StatelessWidget {
  final String id;
  final Widget child;

  /// Builds the item with another label, for plugin `rename` rules. Items without it cannot be renamed.
  final Widget Function(String label)? relabel;

  const BuiltinSlotItem({super.key, required this.id, required this.child, this.relabel});

  @override
  Widget build(BuildContext context) => child;
}
