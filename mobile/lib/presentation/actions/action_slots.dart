import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/builtin_rules.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_registry.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';
import 'package:immich_mobile/providers/timeline/timeline_plugins.provider.dart';

/// An action shown under another label (a plugin `rename` rule).
class RenamedActionBuilder extends ActionBuilder {
  final ActionBuilder action;
  final String label;

  const RenamedActionBuilder(this.action, this.label);

  @override
  String? get id => action.id;

  @override
  ActionSource? get hookSource => action.hookSource;

  @override
  Map<String, dynamic> get hookArgs => action.hookArgs;

  @override
  List<BaseAsset> hookAssets(WidgetRef ref) => action.hookAssets(ref);

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) => action.create(context, ref)?.copyWith(label: label);
}

/// The id plugin rules use for an item of a bar or menu: the action id of an [ActionBuilder] or [ActionWidget], the
/// id of a [BuiltinSlotItem], else null (never hidden or moved by id).
String? slotItemId(Object? item) => switch (item) {
  final ActionBuilder action => action.id,
  final ActionWidget widget => widget.action.id,
  final BuiltinSlotItem widget => widget.id,
  _ => null,
};

/// [actions] of the bar or menu that reads [slots] (generic slot first), with plugin rules applied (hide, order,
/// rename) and plugin actions of those slots merged in. Returns [actions] itself when no plugin touches the slots.
/// Call it in `build`: it rebuilds the caller when plugin contributions change.
List<ActionBuilder> arrangeActions(
  WidgetRef ref,
  List<String> slots,
  List<ActionBuilder> actions, {
  ActionSource source = ActionSource.timeline,
}) {
  final bridge = ref.watch(timelinePluginBridgeProvider);
  final rules = bridge.rules(slots);
  final extra = [for (final slot in slots) ...bridge.actions(slot, source: source)];
  final arranged = arrangeSlotItems<ActionBuilder>(actions, slotItemId, rules: rules, extra: extra);
  if (rules.rename.isEmpty) {
    return arranged;
  }
  return [
    for (final action in arranged)
      switch (rules.rename[action.id]) {
        final String label => RenamedActionBuilder(action, label),
        null => action,
      },
  ];
}

/// [arrangeActions] for a list of widgets, as bars and sheets hold them: [ActionWidget]s and [BuiltinSlotItem]s are
/// addressed by id, other widgets keep their relative place. Plugin actions are presented by [present] (default: an
/// [ActionColumnButton]).
List<Widget> arrangeActionWidgets(
  WidgetRef ref,
  List<String> slots,
  List<Widget> widgets, {
  ActionWidget Function(ActionBuilder action)? present,
  ActionSource source = ActionSource.timeline,
}) {
  final bridge = ref.watch(timelinePluginBridgeProvider);
  final rules = bridge.rules(slots);
  final extraActions = [for (final slot in slots) ...bridge.actions(slot, source: source)];
  if (rules.isEmpty && extraActions.isEmpty) {
    return widgets;
  }
  final presenter = present ?? (action) => ActionColumnButton(action: action);
  final extra = [
    for (final item in extraActions) SlotExtraItem<Widget>(id: item.id, item: presenter(item.item), order: item.order),
  ];
  final arranged = arrangeSlotItems<Widget>(widgets, slotItemId, rules: rules, extra: extra);
  return rules.rename.isEmpty ? arranged : [for (final widget in arranged) _rename(widget, rules)];
}

/// Plugin rules and plugin buttons (and toggles) for a row of app bar buttons; [builtins] are usually
/// [BuiltinSlotItem]s. Returns [builtins] itself when no plugin touches [slot].
List<Widget> arrangeButtons(
  WidgetRef ref,
  String slot,
  List<Widget> builtins, {
  Map<String, dynamic> context = const {},
}) {
  final bridge = ref.watch(timelinePluginBridgeProvider);
  return _arrangeWidgets(bridge.rules([slot]), builtins, bridge.buttons(slot, context));
}

/// Plugin rules and plugin entries for an overflow menu; [builtins] are usually [BuiltinSlotItem]s.
List<Widget> arrangeMenuItems(
  WidgetRef ref,
  String slot,
  List<Widget> builtins, {
  Map<String, dynamic> context = const {},
}) {
  final bridge = ref.watch(timelinePluginBridgeProvider);
  return _arrangeWidgets(bridge.rules([slot]), builtins, bridge.menuItems(slot, context));
}

List<Widget> _arrangeWidgets(BuiltinItemRules rules, List<Widget> builtins, List<SlotExtraItem<Widget>> extra) {
  if (rules.isEmpty && extra.isEmpty) {
    return builtins;
  }
  final arranged = arrangeSlotItems<Widget>(builtins, slotItemId, rules: rules, extra: extra);
  return rules.rename.isEmpty ? arranged : [for (final widget in arranged) _rename(widget, rules)];
}

Widget _rename(Widget widget, BuiltinItemRules rules) {
  final id = slotItemId(widget);
  final label = id == null ? null : rules.rename[id];
  if (label == null) {
    return widget;
  }
  return switch (widget) {
    final ActionWidget action => action.withAction(RenamedActionBuilder(action.action, label)),
    BuiltinSlotItem(:final id, :final relabel?) => BuiltinSlotItem(id: id, child: relabel(label)),
    _ => widget,
  };
}

/// Records what the actions of one bar or sheet resolved to while they build, so plugins can list and run them
/// (`actions.list`, `actions.run`). Register it with [TimelineRegistry.registerSurface] while the bar is mounted
/// and put an [ActionSurfaceScope] above its action widgets.
class ActionSurfaceRecorder implements ActionSurfaceHandle {
  @override
  final String surface;

  final bool Function() _isVisible;

  /// Makes [assetIds] the assets the actions run on (the selection); completes once the bar rebuilt for them.
  final Future<void> Function(List<String> assetIds)? _useAssets;

  final Map<String, ActionItem?> _items = {};
  List<String?> _order = const [];

  ActionSurfaceRecorder({required this.surface, required this._isVisible, this._useAssets});

  @override
  bool get isVisible => _isVisible();

  /// The actions of the bar in display order (after [arrangeActions]); call in the bar's build.
  void setOrder(Iterable<Object?> items) => _order = [for (final item in items) slotItemId(item)];

  /// Called by [ActionWidget.build] with what its action resolved to (null when it does not apply).
  void record(String id, ActionItem? item) => _items[id] = item;

  @override
  List<Map<String, dynamic>> listActions() => [
    for (final id in _order)
      if (id != null)
        if (_items[id] case final item?)
          {
            'id': id,
            'label': item.label,
            'icon': item.icon.codePoint,
            'builtin': !id.startsWith(builtinRulesPluginPrefix),
          },
  ];

  @override
  Future<bool> runAction(String actionId, List<String>? assetIds) async {
    final useAssets = _useAssets;
    if (assetIds != null && useAssets != null) {
      await useAssets(assetIds);
    }
    final item = _items[actionId];
    if (item == null) {
      return false;
    }
    await item.onAction();
    return true;
  }
}

/// Gives the [ActionWidget]s below it the [ActionSurfaceRecorder] of their bar.
class ActionSurfaceScope extends InheritedWidget {
  final ActionSurfaceRecorder recorder;

  const ActionSurfaceScope({super.key, required this.recorder, required super.child});

  static ActionSurfaceRecorder? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ActionSurfaceScope>()?.recorder;

  @override
  bool updateShouldNotify(ActionSurfaceScope oldWidget) => !identical(recorder, oldWidget.recorder);
}

/// Waits until the next frame is drawn, so widgets rebuilt for a state change.
Future<void> nextFrame() {
  final completer = Completer<void>();
  WidgetsBinding.instance
    ..addPostFrameCallback((_) => completer.complete())
    ..scheduleFrame();
  return completer.future;
}
