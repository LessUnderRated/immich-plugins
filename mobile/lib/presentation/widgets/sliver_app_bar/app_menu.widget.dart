import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_mobile/presentation/actions/action_slots.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/base_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// The trailing actions of a home tab app bar (Photos, Albums, Private): a settings gear and the app menu.
///
/// Plugins add buttons and toggles here (`app.appBar.actions`, built-ins `settings`, `menu`) and entries to the menu
/// (`app.menu`). [menuItems] are page entries shown at the top of the menu; wrap them in [BuiltinSlotItem] to give
/// plugins an id for them. [color] tints the icons (e.g. white over a photo header).
class AppBarMenuActions extends ConsumerWidget {
  final List<Widget> menuItems;
  final Color? color;

  const AppBarMenuActions({super.key, this.menuItems = const [], this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = arrangeButtons(ref, TimelineSlots.appActions, [
      BuiltinSlotItem(
        id: TimelineItemIds.settingsButton,
        child: AppSettingsButton(color: color),
      ),
      BuiltinSlotItem(
        id: TimelineItemIds.appMenu,
        child: AppMenuButton(items: menuItems, color: color),
      ),
    ]);
    return Row(mainAxisSize: MainAxisSize.min, children: actions);
  }
}

/// A settings gear that opens the Settings page.
class AppSettingsButton extends StatelessWidget {
  final Color? color;

  const AppSettingsButton({super.key, this.color});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: context.t.settings,
    color: color,
    icon: const Icon(Icons.settings_outlined),
    onPressed: () => unawaited(context.pushRoute(const SettingsRoute())),
  );
}

/// The app's ⋮ menu: [items] of the page, then Settings, Plugins, Trash, Locked folder (when a server is set up)
/// and Logs. Plugins hide, reorder and rename the built-in entries and add their own through slot `app.menu`
/// (built-in ids `settings`, `plugins`, `trash`, `lockedFolder`, `appLogs`).
class AppMenuButton extends ConsumerWidget {
  final List<Widget> items;
  final Color? color;

  const AppMenuButton({super.key, this.items = const [], this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasServer = ref.watch(storeServiceProvider).tryGet(StoreKey.serverEndpoint)?.isNotEmpty ?? false;

    BuiltinSlotItem entry(String id, IconData icon, String label, PageRouteInfo route) => BuiltinSlotItem(
      id: id,
      relabel: (label) => _MenuEntry(icon: icon, label: label, route: route),
      child: _MenuEntry(icon: icon, label: label, route: route),
    );

    final builtins = [
      entry(TimelineItemIds.settings, Icons.settings_outlined, context.t.settings, const SettingsRoute()),
      entry(TimelineItemIds.plugins, Icons.extension_outlined, context.t.plugins, const PluginsRoute()),
      entry(TimelineItemIds.trash, Icons.delete_outline, context.t.trash, const DeviceTrashRoute()),
      if (hasServer)
        entry(TimelineItemIds.lockedFolder, Icons.lock_outline, context.t.locked_folder, const LockedFolderRoute()),
      entry(
        TimelineItemIds.appLogs,
        Icons.receipt_long_outlined,
        context.t.profile_drawer_app_logs,
        const AppLogRoute(),
      ),
    ];
    final entries = arrangeMenuItems(ref, TimelineSlots.appMenu, builtins);

    return AppBarOverflowMenu(
      color: color,
      tooltip: context.t.menu,
      children: [...items, if (items.isNotEmpty && entries.isNotEmpty) const Divider(height: 1), ...entries],
    );
  }
}

class _MenuEntry extends StatelessWidget {
  final IconData icon;
  final String label;
  final PageRouteInfo route;

  const _MenuEntry({required this.icon, required this.label, required this.route});

  @override
  Widget build(BuildContext context) => BaseActionButton(
    iconData: icon,
    label: label,
    menuItem: true,
    onPressed: () => unawaited(context.pushRoute(route)),
  );
}

/// A ⋮ button opening a menu of [children] (usually `BaseActionButton(menuItem: true)` entries), styled like the
/// app's other menus. Renders nothing when [children] is empty.
class AppBarOverflowMenu extends StatelessWidget {
  final List<Widget> children;
  final Color? color;
  final String? tooltip;

  const AppBarOverflowMenu({super.key, required this.children, this.color, this.tooltip});

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }
    return MenuAnchor(
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(context.themeData.scaffoldBackgroundColor),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.grey),
        elevation: const WidgetStatePropertyAll(4),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      ),
      menuChildren: children,
      builder: (context, controller, child) => IconButton(
        tooltip: tooltip,
        color: color,
        icon: const Icon(Icons.more_vert_rounded),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// The actions of a page's own app bar with plugin support: [actions] (`<page>.appBar.actions`) followed by a ⋮
/// menu of [menu] (`<page>.appBar.menu`) when it has entries. Wrap built-ins in [BuiltinSlotItem] to give them ids.
///
/// Only for pages with their own app bar; the shared app bars (`ImmichSliverAppBar`, `MesmerizingSliverAppBar`, ...)
/// render the page slots themselves.
class PageAppBarActions extends ConsumerWidget {
  final String page;
  final List<Widget> actions;
  final List<Widget> menu;
  final Map<String, dynamic> slotContext;
  final Color? color;

  const PageAppBarActions({
    super.key,
    required this.page,
    this.actions = const [],
    this.menu = const [],
    this.slotContext = const {},
    this.color,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slotContext = {'page': page, ...this.slotContext};
    final buttons = arrangeButtons(ref, TimelineSlots.appBarActions(page), actions, context: slotContext);
    final entries = arrangeMenuItems(ref, TimelineSlots.appBarMenu(page), menu, context: slotContext);
    if (entries.isEmpty && buttons.length <= 1) {
      return buttons.singleOrNull ?? const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...buttons,
        if (entries.isNotEmpty) AppBarOverflowMenu(color: color, children: entries),
      ],
    );
  }
}
