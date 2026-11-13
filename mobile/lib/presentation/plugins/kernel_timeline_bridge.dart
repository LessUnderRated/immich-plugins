import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/builtin_rules.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/plugins/plugin_icons.dart';
import 'package:immich_mobile/presentation/plugins/plugin_slot.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';

/// The [TimelinePluginBridge] backed by the plugin kernel: builtins rules, plugin buttons, menu items, actions,
/// content, decorations and tabs come from the installed plugins' contributions. Shared by every bar, menu, sheet and
/// list that goes through the timeline area's arrange helpers (timeline, shell lists, library, viewer).
class KernelTimelinePluginBridge extends TimelinePluginBridge {
  final PluginKernel _kernel;
  StreamSubscription<Set<String>>? _hooks;
  int _queryRevision = 0;

  static const _queryHook = 'timeline.query';
  static const _buttonKinds = {PluginSlotKind.button, PluginSlotKind.toggle};
  static const _menuKinds = {
    PluginSlotKind.menuItem,
    PluginSlotKind.button,
    PluginSlotKind.toggle,
    PluginSlotKind.page,
  };
  static const _contentKinds = {PluginSlotKind.section, PluginSlotKind.view, PluginSlotKind.panel};
  static const _decorationKinds = {PluginSlotKind.badge, PluginSlotKind.wrap, PluginSlotKind.replace};

  KernelTimelinePluginBridge(this._kernel) {
    _kernel.addListener(notifyListeners);
    _hooks = _kernel.hookChanges.listen((changed) {
      if (changed.contains(_queryHook)) {
        _queryRevision++;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _kernel.removeListener(notifyListeners);
    unawaited(_hooks?.cancel());
    super.dispose();
  }

  static String itemId(SlotContribution item) => '$builtinRulesPluginPrefix${item.plugin}/${item.id}';

  static double _order(SlotContribution item) =>
      item.order == SlotContribution.defaultOrder ? builtinRulesLast : item.order.toDouble();

  List<SlotContribution> _items(String slot, Set<PluginSlotKind> kinds, Map<String, dynamic> context) {
    if (!_kernel.hasSlot(slot)) {
      return const [];
    }
    return [
      for (final item in _kernel.slot(slot, context: context))
        if (kinds.contains(item.kind)) item,
    ];
  }

  @override
  BuiltinItemRules rules(List<String> slots) {
    final hide = <String>{};
    final order = <String>[];
    final rename = <String, String>{};
    for (final slot in slots) {
      final rules = _kernel.builtins(slot);
      hide.addAll(rules.hide);
      for (final id in rules.order) {
        if (!order.contains(id)) {
          order.add(id);
        }
      }
      rename.addAll(rules.rename);
    }
    if (hide.isEmpty && order.isEmpty && rename.isEmpty) {
      return BuiltinItemRules.none;
    }
    return BuiltinItemRules(hide: hide, order: order, rename: rename);
  }

  @override
  List<SlotExtraItem<ActionBuilder>> actions(String slot, {ActionSource source = ActionSource.timeline}) {
    if (!_kernel.hasSlot(slot)) {
      return const [];
    }
    return [
      for (final item in _kernel.slot(slot))
        if (_menuKinds.contains(item.kind) && item.kind != PluginSlotKind.toggle)
          SlotExtraItem(id: itemId(item), item: _PluginSlotAction(_kernel, slot, item, source), order: _order(item)),
    ];
  }

  @override
  List<SlotExtraItem<Widget>> buttons(String slot, Map<String, dynamic> context) => [
    for (final item in _items(slot, _buttonKinds, context))
      SlotExtraItem(
        id: itemId(item),
        item: PluginSlotItemView(item: item, presentation: PluginSlotPresentation.buttons, slotContext: context),
        order: _order(item),
      ),
  ];

  @override
  List<SlotExtraItem<Widget>> menuItems(String slot, Map<String, dynamic> context) => [
    for (final item in _items(slot, _menuKinds, context))
      SlotExtraItem(
        id: itemId(item),
        item: PluginSlotItemView(item: item, presentation: PluginSlotPresentation.menu, slotContext: context),
        order: _order(item),
      ),
  ];

  @override
  bool hasContent(String slot) =>
      _kernel.hasSlot(slot) && _kernel.slot(slot).any((i) => _contentKinds.contains(i.kind));

  @override
  Widget? content(String slot, Map<String, dynamic> context) {
    final items = _items(slot, _contentKinds, context);
    if (items.isEmpty) {
      return null;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final item in items) PluginSlotContent(item: item, slotContext: context)],
    );
  }

  @override
  bool hasDecorations(String slot) =>
      _kernel.hasSlot(slot) && _kernel.slot(slot).any((i) => _decorationKinds.contains(i.kind));

  @override
  Widget decorate(String slot, Map<String, dynamic> context, Widget child) {
    if (!hasDecorations(slot)) {
      return child;
    }
    final badges = _items(slot, const {PluginSlotKind.badge}, context);
    final decorated = PluginReplaceable(slot: slot, slotContext: context, child: child);
    if (badges.isEmpty) {
      return decorated;
    }
    return Stack(
      fit: StackFit.passthrough,
      children: [
        decorated,
        Positioned(
          top: 4,
          right: 4,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (final b in badges) PluginStaticBadge(item: b)],
          ),
        ),
      ],
    );
  }

  @override
  List<TimelinePluginTab> get tabs => [
    for (final tab in _kernel.tabs)
      TimelinePluginTab(
        id: '$builtinRulesPluginPrefix${tab.plugin}/${tab.id}',
        title: tab.title,
        icon: pluginIconData(tab.icon) ?? Icons.extension_outlined,
        selectedIcon: pluginIconData(tab.selectedIcon),
        order: tab.order == SlotContribution.defaultOrder ? builtinRulesLast : tab.order.toDouble(),
        builder: (_) => PluginTabView(tab: tab),
      ),
  ];

  @override
  int get queryRevision => _queryRevision;
}

/// A plugin `button`/`menuItem` contribution of an action slot, presented like a built-in action. It applies when its
/// `when` matches the current assets; running it sends `SlotV1` with those assets.
class _PluginSlotAction extends ActionBuilder {
  final PluginKernel _kernel;
  final String _slot;
  final SlotContribution _item;
  final ActionSource _source;

  const _PluginSlotAction(this._kernel, this._slot, this._item, this._source);

  @override
  String get id => KernelTimelinePluginBridge.itemId(_item);

  @override
  List<BaseAsset> hookAssets(WidgetRef ref) => ref.read(assetsActionProvider(_source)).toList();

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(assetsActionProvider(_source)).toList();
    final slotContext = PluginKernel.assetContext(assets);
    final applies = _kernel
        .slot(_slot, context: slotContext)
        .any((item) => item.plugin == _item.plugin && item.id == _item.id);
    if (!applies) {
      return null;
    }
    return ActionItem(
      icon: pluginIconData(_item.icon) ?? Icons.extension_outlined,
      label: _item.title,
      onAction: () => _kernel.runSlot(_item, context: slotContext, assets: assets, buildContext: context),
    );
  }
}
