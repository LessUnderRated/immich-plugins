import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/presentation/plugins/plugin_ui.dart';
import 'package:immich_mobile/presentation/plugins/plugin_ui_renderer.dart';
import 'package:immich_mobile/providers/plugin_kernel.provider.dart';

export 'package:immich_mobile/domain/plugins/plugin_ids.dart' show PluginSlotKind;

/// How a slot shows its plugin items. The call site decides the presentation; each presentation renders the item
/// kinds that fit it (override with `kinds`).
enum PluginSlotPresentation {
  /// Icon buttons in a row (app bars, viewer bars): `button`, `toggle`.
  buttons,

  /// `MenuItemButton`s (inside `MenuAnchor` menus): `menuItem`, `button`, `toggle`, `page`.
  menu,

  /// List tiles (settings lists, sheets): `tile`, `page`, `button`, `menuItem`, `toggle` (as a switch tile).
  tiles,

  /// Blocks of JSON UI or native views (pages, sheets, info panels): `section`, `panel`, `view`.
  sections,

  /// Chips in a wrap: `chip`, `button`, `toggle` (as a filter chip).
  chips,

  /// A side or bottom panel: `panel`, `section`, `view`.
  panel,

  /// Native views only: `view`.
  views,

  /// Toggle icon buttons only: `toggle`.
  toggles,
}

/// Item kinds each presentation renders by default.
const pluginPresentationKinds = <PluginSlotPresentation, Set<PluginSlotKind>>{
  PluginSlotPresentation.buttons: {PluginSlotKind.button, PluginSlotKind.toggle},
  PluginSlotPresentation.menu: {PluginSlotKind.menuItem, PluginSlotKind.button, PluginSlotKind.toggle, PluginSlotKind.page},
  PluginSlotPresentation.tiles: {
    PluginSlotKind.tile,
    PluginSlotKind.page,
    PluginSlotKind.button,
    PluginSlotKind.menuItem,
    PluginSlotKind.toggle,
  },
  PluginSlotPresentation.sections: {PluginSlotKind.section, PluginSlotKind.panel, PluginSlotKind.view},
  PluginSlotPresentation.chips: {PluginSlotKind.chip, PluginSlotKind.button, PluginSlotKind.toggle},
  PluginSlotPresentation.panel: {PluginSlotKind.panel, PluginSlotKind.section, PluginSlotKind.view},
  PluginSlotPresentation.views: {PluginSlotKind.view},
  PluginSlotPresentation.toggles: {PluginSlotKind.toggle},
};

/// The full slot context for [assets] and [slotContext] (asset fields first, explicit fields win).
Map<String, dynamic> pluginSlotContext(List<BaseAsset> assets, Map<String, dynamic> slotContext) =>
    assets.isEmpty && slotContext.isEmpty ? const {} : {...PluginKernel.assetContext(assets), ...slotContext};

/// Plugin items of one slot, in one presentation. Renders nothing (zero cost) when no plugin contributes to it.
///
/// ```dart
/// PluginSlot.buttons(slot: 'albumOptions.appBar.actions', slotContext: {'albumId': album.id})
/// PluginSlot.sections(slot: 'viewer.info.sections', assets: [asset])
/// ```
/// Static content (title, icon, `ui`) renders synchronously; `uiMethod` content is fetched (`SlotV1`, event
/// `content`) and cached per slot, plugin, item and context until `refreshSlots`. Taps run `SlotV1` and perform the
/// response.
class PluginSlot extends ConsumerWidget {
  final String slot;
  final PluginSlotPresentation presentation;

  /// JSON context of the slot (where it is); matched by `when` and sent to plugins.
  final Map<String, dynamic> slotContext;

  /// Assets the slot is about (selection, viewer asset); sent as AssetV1 and summarized into the context.
  final List<BaseAsset> assets;

  /// Kinds to render instead of the presentation's defaults.
  final Set<PluginSlotKind>? kinds;
  final Color? color;
  final double? iconSize;
  final EdgeInsetsGeometry? padding;
  final double spacing;

  const PluginSlot({
    super.key,
    required this.slot,
    this.presentation = PluginSlotPresentation.buttons,
    this.slotContext = const {},
    this.assets = const [],
    this.kinds,
    this.color,
    this.iconSize,
    this.padding,
    this.spacing = 8,
  });

  const PluginSlot.buttons({
    super.key,
    required this.slot,
    this.slotContext = const {},
    this.assets = const [],
    this.kinds,
    this.color,
    this.iconSize,
    this.padding,
    this.spacing = 0,
  }) : presentation = PluginSlotPresentation.buttons;

  const PluginSlot.menu({
    super.key,
    required this.slot,
    this.slotContext = const {},
    this.assets = const [],
    this.kinds,
    this.color,
    this.iconSize,
    this.padding,
    this.spacing = 0,
  }) : presentation = PluginSlotPresentation.menu;

  const PluginSlot.tiles({
    super.key,
    required this.slot,
    this.slotContext = const {},
    this.assets = const [],
    this.kinds,
    this.color,
    this.iconSize,
    this.padding,
    this.spacing = 0,
  }) : presentation = PluginSlotPresentation.tiles;

  const PluginSlot.sections({
    super.key,
    required this.slot,
    this.slotContext = const {},
    this.assets = const [],
    this.kinds,
    this.color,
    this.iconSize,
    this.padding,
    this.spacing = 8,
  }) : presentation = PluginSlotPresentation.sections;

  const PluginSlot.chips({
    super.key,
    required this.slot,
    this.slotContext = const {},
    this.assets = const [],
    this.kinds,
    this.color,
    this.iconSize,
    this.padding,
    this.spacing = 8,
  }) : presentation = PluginSlotPresentation.chips;

  const PluginSlot.panel({
    super.key,
    required this.slot,
    this.slotContext = const {},
    this.assets = const [],
    this.kinds,
    this.color,
    this.iconSize,
    this.padding,
    this.spacing = 8,
  }) : presentation = PluginSlotPresentation.panel;

  const PluginSlot.views({
    super.key,
    required this.slot,
    this.slotContext = const {},
    this.assets = const [],
    this.kinds,
    this.color,
    this.iconSize,
    this.padding,
    this.spacing = 8,
  }) : presentation = PluginSlotPresentation.views;

  const PluginSlot.toggles({
    super.key,
    required this.slot,
    this.slotContext = const {},
    this.assets = const [],
    this.kinds,
    this.color,
    this.iconSize,
    this.padding,
    this.spacing = 0,
  }) : presentation = PluginSlotPresentation.toggles;

  /// Plugin items of [slot] as `PopupMenuButton` entries (`menuItem`, `button`, `toggle` as a checked item, `page`).
  static List<PopupMenuEntry<T>> popupMenuItems<T>(
    WidgetRef ref,
    BuildContext context,
    String slot, {
    Map<String, dynamic> slotContext = const {},
    List<BaseAsset> assets = const [],
    Set<PluginSlotKind>? kinds,
  }) {
    final kernel = ref.read(pluginKernelProvider);
    if (!kernel.hasSlot(slot)) {
      return const [];
    }
    final full = pluginSlotContext(assets, slotContext);
    return [
      for (final item in kernel.slot(slot, context: full))
        if ((kinds ?? pluginPresentationKinds[PluginSlotPresentation.menu]!).contains(item.kind))
          pluginPopupMenuItem<T>(ref, context, item, slotContext: full, assets: assets),
    ];
  }

  /// Plugin items of [slot] as `MenuItemButton`s for `MenuAnchor.menuChildren`.
  static List<Widget> menuItemButtons(
    WidgetRef ref,
    BuildContext context,
    String slot, {
    Map<String, dynamic> slotContext = const {},
    List<BaseAsset> assets = const [],
    Set<PluginSlotKind>? kinds,
  }) {
    final kernel = ref.read(pluginKernelProvider);
    if (!kernel.hasSlot(slot)) {
      return const [];
    }
    final full = pluginSlotContext(assets, slotContext);
    return [
      for (final item in kernel.slot(slot, context: full))
        if ((kinds ?? pluginPresentationKinds[PluginSlotPresentation.menu]!).contains(item.kind))
          PluginSlotItemView(item: item, presentation: PluginSlotPresentation.menu, slotContext: full, assets: assets),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kernel = ref.watch(pluginKernelProvider);
    if (!kernel.hasSlot(slot)) {
      return const SizedBox.shrink();
    }
    final full = pluginSlotContext(assets, slotContext);
    final wanted = kinds ?? pluginPresentationKinds[presentation]!;
    final items = [
      for (final item in kernel.slot(slot, context: full))
        if (wanted.contains(item.kind)) item,
    ];
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    final children = [
      for (final item in items)
        PluginSlotItemView(
          key: ValueKey(item.key),
          item: item,
          presentation: presentation,
          slotContext: full,
          assets: assets,
          color: color,
          iconSize: iconSize,
        ),
    ];
    final Widget body = switch (presentation) {
      PluginSlotPresentation.buttons || PluginSlotPresentation.toggles => Row(
        mainAxisSize: MainAxisSize.min,
        spacing: spacing,
        children: children,
      ),
      PluginSlotPresentation.chips => Wrap(spacing: spacing, runSpacing: spacing / 2, children: children),
      PluginSlotPresentation.menu || PluginSlotPresentation.tiles => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: spacing,
        children: children,
      ),
      _ => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: spacing,
        children: children,
      ),
    };
    return padding == null ? body : Padding(padding: padding!, child: body);
  }
}

/// One plugin slot item in a presentation. Use it to merge plugin items into a built-in list (see
/// [PluginBuiltins.arrange]).
class PluginSlotItemView extends ConsumerWidget {
  final SlotContribution item;
  final PluginSlotPresentation presentation;
  final Map<String, dynamic> slotContext;
  final List<BaseAsset> assets;
  final Color? color;
  final double? iconSize;

  const PluginSlotItemView({
    super.key,
    required this.item,
    required this.presentation,
    this.slotContext = const {},
    this.assets = const [],
    this.color,
    this.iconSize,
  });

  void _run(WidgetRef ref, BuildContext context) =>
      unawaited(runPluginSlotItem(ref, item, slotContext: slotContext, assets: assets, context: context));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = item.isToggle && ref.watch(pluginToggleProvider(item.toggleKey));
    final icon = PluginIcon(
      plugin: item.plugin,
      icon: on ? item.activeIcon ?? item.icon : item.icon,
      color: color,
      size: iconSize,
    );
    final title = on ? item.activeTitle ?? item.title : item.title;
    switch (presentation) {
      case PluginSlotPresentation.buttons:
      case PluginSlotPresentation.toggles:
        return IconButton(
          tooltip: item.tooltip ?? title,
          color: color,
          iconSize: iconSize,
          isSelected: item.isToggle ? on : null,
          icon: icon,
          onPressed: () => _run(ref, context),
        );
      case PluginSlotPresentation.menu:
        return MenuItemButton(
          leadingIcon: item.icon == null ? null : icon,
          trailingIcon: item.isToggle ? Icon(on ? Icons.check_box : Icons.check_box_outline_blank) : null,
          onPressed: () => _run(ref, context),
          child: Text(title, style: item.destructive ? TextStyle(color: Theme.of(context).colorScheme.error) : null),
        );
      case PluginSlotPresentation.tiles:
        if (item.isToggle) {
          return SwitchListTile(
            value: on,
            title: Text(title),
            subtitle: item.subtitle == null ? null : Text(item.subtitle!),
            secondary: item.icon == null ? null : icon,
            onChanged: (_) => _run(ref, context),
          );
        }
        return ListTile(
          leading: icon,
          title: Text(title),
          subtitle: item.subtitle == null ? null : Text(item.subtitle!),
          trailing: item.kind == PluginSlotKind.page ? const Icon(Icons.chevron_right) : null,
          onTap: () => _run(ref, context),
        );
      case PluginSlotPresentation.chips:
        if (item.isToggle) {
          return FilterChip(
            label: Text(title),
            avatar: item.icon == null ? null : icon,
            selected: on,
            onSelected: (_) => _run(ref, context),
          );
        }
        return ActionChip(label: Text(title), avatar: item.icon == null ? null : icon, onPressed: () => _run(ref, context));
      case PluginSlotPresentation.sections:
      case PluginSlotPresentation.panel:
      case PluginSlotPresentation.views:
        return PluginSlotContent(item: item, slotContext: slotContext, assets: assets);
    }
  }
}

/// A plugin slot item as a `PopupMenuButton` entry.
PopupMenuEntry<T> pluginPopupMenuItem<T>(
  WidgetRef ref,
  BuildContext context,
  SlotContribution item, {
  Map<String, dynamic> slotContext = const {},
  List<BaseAsset> assets = const [],
}) {
  void run() =>
      unawaited(runPluginSlotItem(ref, item, slotContext: slotContext, assets: assets, context: context));
  if (item.isToggle) {
    return CheckedPopupMenuItem<T>(
      checked: ref.read(pluginKernelProvider).toggles.get(item.toggleKey),
      onTap: run,
      child: Text(item.title),
    );
  }
  return PopupMenuItem<T>(
    onTap: run,
    child: Row(
      children: [
        if (item.icon != null) ...[PluginIcon(plugin: item.plugin, icon: item.icon, size: 20), const SizedBox(width: 12)],
        Expanded(
          child: Text(
            item.title,
            style: item.destructive ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
          ),
        ),
      ],
    ),
  );
}

/// The content of a `section` / `panel` / `view` / `replace` / `wrap` / `badge` item: its native view, its static
/// `ui`, or its `uiMethod` content (fetched once per context and cached; [fallback] shows meanwhile and when there is
/// none). The content's JSON UI surface id is `slot:<slot>/<id>` (plus `#<assetId>` for one-asset contexts).
class PluginSlotContent extends ConsumerStatefulWidget {
  final SlotContribution item;
  final Map<String, dynamic> slotContext;
  final List<BaseAsset> assets;
  final Widget? fallback;

  const PluginSlotContent({
    super.key,
    required this.item,
    this.slotContext = const {},
    this.assets = const [],
    this.fallback,
  });

  @override
  ConsumerState<PluginSlotContent> createState() => _PluginSlotContentState();
}

class _PluginSlotContentState extends ConsumerState<PluginSlotContent> {
  Future<void>? _pending;

  void _fetch(PluginKernel kernel) {
    _pending ??= kernel
        .slotUi(widget.item, context: widget.slotContext, assets: widget.assets)
        .then((_) {
          _pending = null;
          if (mounted) {
            setState(() {});
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    final kernel = ref.watch(pluginKernelProvider);
    final item = widget.item;
    final fallback = widget.fallback ?? const SizedBox.shrink();
    final view = item.view;
    if (view != null) {
      return PluginView(
        plugin: item.plugin,
        view: view,
        params: {...item.params, 'context': widget.slotContext},
        composition: item.composition,
        interactive: item.interactive || item.kind == PluginSlotKind.view || item.kind == PluginSlotKind.panel,
        height: item.height,
        defaultHeight: item.kind == PluginSlotKind.replace || item.kind == PluginSlotKind.wrap ? null : 160,
      );
    }
    if (item.ui == null && item.uiMethod == null) {
      return fallback;
    }
    if (!kernel.isSlotUiResolved(item, context: widget.slotContext)) {
      _fetch(kernel);
      return fallback;
    }
    final ui = kernel.cachedSlotUi(item, context: widget.slotContext);
    if (ui == null) {
      return fallback;
    }
    return PluginUiView(
      plugin: item.plugin,
      ui: ui,
      method: item.method ?? item.uiMethod,
      page: item.id,
      params: item.params,
      eventContext: widget.slotContext,
      surface: PluginKernel.slotSurfaceId(item, widget.slotContext),
    );
  }
}

/// A built-in widget plugins can replace (`replace`), decorate (`wrap`: drawn over it) or badge (`badge`) by slot id.
/// Returns [child] itself when no plugin targets [slot].
class PluginReplaceable extends ConsumerWidget {
  final String slot;
  final Widget child;
  final Map<String, dynamic> slotContext;
  final List<BaseAsset> assets;

  const PluginReplaceable({
    super.key,
    required this.slot,
    required this.child,
    this.slotContext = const {},
    this.assets = const [],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kernel = ref.watch(pluginKernelProvider);
    if (!kernel.hasSlot(slot)) {
      return child;
    }
    final full = pluginSlotContext(assets, slotContext);
    final items = kernel.slot(slot, context: full);
    final replace = items.where((item) => item.kind == PluginSlotKind.replace).firstOrNull;
    final wraps = [
      for (final item in items)
        if (item.kind == PluginSlotKind.wrap || item.kind == PluginSlotKind.badge) item,
    ];
    if (replace == null && wraps.isEmpty) {
      return child;
    }
    final base = replace == null
        ? child
        : PluginSlotContent(item: replace, slotContext: full, assets: assets, fallback: child);
    if (wraps.isEmpty) {
      return base;
    }
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        base,
        for (final item in wraps)
          item.kind == PluginSlotKind.badge
              ? _badge(item, full)
              : Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !item.interactive,
                    child: PluginSlotContent(item: item, slotContext: full, assets: assets),
                  ),
                ),
      ],
    );
  }

  Widget _badge(SlotContribution item, Map<String, dynamic> full) {
    final content = IgnorePointer(
      ignoring: !item.interactive,
      child: item.ui != null || item.uiMethod != null || item.view != null
          ? PluginSlotContent(item: item, slotContext: full, assets: assets)
          : PluginStaticBadge(item: item),
    );
    final position = item.position;
    if (position.isNotEmpty) {
      return Positioned(
        left: position['left'],
        top: position['top'],
        right: position['right'],
        bottom: position['bottom'],
        width: position['width'],
        height: position['height'],
        child: content,
      );
    }
    return Positioned.fill(
      child: Align(
        alignment: pluginAlignment(item.alignment) ?? Alignment.topRight,
        child: Padding(padding: const EdgeInsets.all(4), child: content),
      ),
    );
  }
}

/// A badge from static fields: icon and/or title on a small pill.
class PluginStaticBadge extends StatelessWidget {
  final SlotContribution item;

  const PluginStaticBadge({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = pluginColor(context, item.params['color']) ?? scheme.primary;
    final foreground = pluginColor(context, item.params['textColor']) ?? scheme.onPrimary;
    final showTitle = item.params['showTitle'] != false && item.icon == null;
    return DecoratedBox(
      decoration: BoxDecoration(color: color, borderRadius: const BorderRadius.all(Radius.circular(10))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.icon != null) PluginIcon(plugin: item.plugin, icon: item.icon, color: foreground, size: 14),
            if (showTitle)
              Text(item.title, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: foreground)),
          ],
        ),
      ),
    );
  }
}

/// Applies plugin hide / order / rename / icon rules to built-in item lists, and merges plugin items in.
abstract final class PluginBuiltins {
  /// The rules for [slot] (`kernel.builtins(slot)`); as JSON with `.toJson()`: `{ hide, order, rename, icons }`.
  static BuiltinRules rules(PluginKernel kernel, String slot) => kernel.builtins(slot);

  /// [items] with the hidden ones removed and the `order` rule applied (no plugin items). Returns [items] itself
  /// when no rule exists.
  static List<T> apply<T>(PluginKernel kernel, String slot, List<T> items, String Function(T item) idOf) {
    final rules = kernel.builtins(slot);
    return rules.isEmpty ? items : rules.apply(items, idOf);
  }

  /// Built-in items and the plugin items of [slot] (kinds [kinds], matching [slotContext] / [assets]) in display
  /// order: built-in `i` has order `(i + 1) * 100`, plugin items use their `order`; then `hide` and `order` rules.
  static List<PluginSlotEntry<T>> arrange<T>(
    PluginKernel kernel,
    String slot,
    List<T> builtins,
    String Function(T item) idOf, {
    Map<String, dynamic> slotContext = const {},
    List<BaseAsset> assets = const [],
    Set<PluginSlotKind>? kinds,
  }) {
    final rules = kernel.builtins(slot);
    final contributions = kernel.hasSlot(slot)
        ? [
            for (final item in kernel.slot(slot, context: pluginSlotContext(assets, slotContext)))
              if (kinds == null || kinds.contains(item.kind)) item,
          ]
        : const <SlotContribution>[];
    if (rules.isEmpty && contributions.isEmpty) {
      return [for (final item in builtins) BuiltinSlotEntry<T>(item, idOf(item))];
    }
    return rules.arrange(builtins, idOf, contributions);
  }

  /// Widgets for a merged list: [builtin] builds a built-in item (with its renamed label / icon name, if any);
  /// plugin items render in [presentation] (or with [contributed]).
  static List<Widget> build<T>(
    PluginKernel kernel,
    String slot,
    List<T> builtins,
    String Function(T item) idOf, {
    required Widget Function(T item, String? label, String? icon) builtin,
    PluginSlotPresentation presentation = PluginSlotPresentation.buttons,
    Widget Function(SlotContribution item)? contributed,
    Map<String, dynamic> slotContext = const {},
    List<BaseAsset> assets = const [],
    Set<PluginSlotKind>? kinds,
  }) {
    final full = pluginSlotContext(assets, slotContext);
    return [
      for (final entry in arrange(
        kernel,
        slot,
        builtins,
        idOf,
        slotContext: full,
        assets: assets,
        kinds: kinds ?? pluginPresentationKinds[presentation],
      ))
        switch (entry) {
          BuiltinSlotEntry<T>(:final item, :final label, :final icon) => builtin(item, label, icon),
          ContributedSlotEntry<T>(:final contribution) =>
            contributed?.call(contribution) ??
                PluginSlotItemView(
                  key: ValueKey(contribution.key),
                  item: contribution,
                  presentation: presentation,
                  slotContext: full,
                  assets: assets,
                ),
        },
    ];
  }

  /// The label of built-in [id] in [slot] after `rename` rules.
  static String label(PluginKernel kernel, String slot, String id, String fallback) =>
      kernel.builtins(slot).label(id, fallback) ?? fallback;

  /// Whether built-in [id] is hidden in [slot].
  static bool isHidden(PluginKernel kernel, String slot, String id) => kernel.builtins(slot).hides(id);
}

/// An on/off icon button bound to a toggle (`<owner>/<id>`, e.g. `app/viewer.shield`), for built-in code. The state
/// is persisted by the kernel (or by the toggle's definition); plugins read and change it with `toggles.*` and get
/// `toggle.changed`.
class PluginToggleButton extends ConsumerWidget {
  final String toggleKey;
  final Widget icon;
  final Widget? selectedIcon;
  final String? tooltip;
  final String? selectedTooltip;
  final Color? color;
  final ValueChanged<bool>? onChanged;

  const PluginToggleButton({
    super.key,
    required this.toggleKey,
    required this.icon,
    this.selectedIcon,
    this.tooltip,
    this.selectedTooltip,
    this.color,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(pluginToggleProvider(toggleKey));
    return IconButton(
      isSelected: on,
      icon: icon,
      selectedIcon: selectedIcon,
      color: color,
      tooltip: on ? selectedTooltip ?? tooltip : tooltip,
      onPressed: () async {
        final value = await ref.read(pluginKernelProvider).toggles.toggle(toggleKey);
        onChanged?.call(value);
      },
    );
  }
}

/// The body of a plugin page without a route (plugin bottom-navigation tabs, embedded pages): a JSON UI page
/// ([method] called with `PageV1`, or static [ui]) or a native [view].
class PluginPageBody extends StatelessWidget {
  final String plugin;
  final String? method;
  final String? page;
  final Map<String, dynamic>? ui;
  final String? view;
  final String? composition;
  final Map<String, dynamic> params;
  final String? surface;

  const PluginPageBody({
    super.key,
    required this.plugin,
    this.method,
    this.page,
    this.ui,
    this.view,
    this.composition,
    this.params = const {},
    this.surface,
  });

  @override
  Widget build(BuildContext context) {
    final view = this.view;
    if (view != null) {
      return PluginView(plugin: plugin, view: view, params: params, composition: composition, interactive: true);
    }
    return PluginUiView(
      plugin: plugin,
      method: method,
      page: page ?? method,
      ui: ui,
      params: params,
      surface: surface ?? 'page:${page ?? method ?? 'ui'}',
      scrollable: true,
    );
  }
}

/// A plugin bottom-navigation tab's content (`contributes.tabs`); surface id `tab:<id>`.
class PluginTabView extends StatelessWidget {
  final TabContribution tab;

  const PluginTabView({super.key, required this.tab});

  @override
  Widget build(BuildContext context) => PluginPageBody(
    plugin: tab.plugin,
    method: tab.uiMethod,
    page: tab.id,
    view: tab.view,
    composition: tab.composition,
    params: tab.params,
    surface: 'tab:${tab.id}',
  );
}

/// A list tile opening a plugin settings page (`contributes.settings`).
class PluginSettingsTile extends ConsumerWidget {
  final SettingsContribution page;

  const PluginSettingsTile({super.key, required this.page});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kernel = ref.watch(pluginKernelProvider);
    final pluginTitle = kernel.plugin(page.plugin)?.title ?? page.plugin;
    return ListTile(
      leading: PluginIcon(plugin: page.plugin, icon: page.icon ?? 'settings'),
      title: Text(page.title),
      subtitle: Text(page.subtitle ?? pluginTitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => unawaited(kernel.openSettingsPage(page.plugin, page.id, context: context)),
    );
  }
}
