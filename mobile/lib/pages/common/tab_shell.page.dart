import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/builtin_rules.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_registry.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:immich_mobile/providers/tab.provider.dart';
import 'package:immich_mobile/providers/timeline/timeline_plugins.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_ui/immich_ui.dart';

const _privateTabIndex = 2;

/// A tab of the bottom navigation: a built-in tab (a route of the [AutoTabsRouter]) or a plugin tab (a page shown
/// over the router without a route of its own).
class _ShellTab {
  final String id;
  final String label;
  final Widget icon;
  final Widget selectedIcon;
  final int? routeIndex;
  final TimelinePluginTab? plugin;

  const _ShellTab({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    this.routeIndex,
    this.plugin,
  });

  _ShellTab relabel(String label) =>
      _ShellTab(id: id, label: label, icon: icon, selectedIcon: selectedIcon, routeIndex: routeIndex, plugin: plugin);

  NavigationDestination get destination => NavigationDestination(label: label, icon: icon, selectedIcon: selectedIcon);
}

@RoutePage()
class TabShellPage extends ConsumerStatefulWidget {
  const TabShellPage({super.key});

  @override
  ConsumerState<TabShellPage> createState() => _TabShellPageState();
}

class _TabShellPageState extends ConsumerState<TabShellPage> implements TabShellHandle {
  /// The plugin tab on screen, or null while a built-in tab (the router's active route) is.
  String? _pluginTab;

  /// Plugin tabs opened so far: kept alive like the router keeps its tabs.
  final Map<String, TimelinePluginTab> _openedPluginTabs = {};

  List<_ShellTab> _tabs = const [];
  TabsRouter? _router;

  @override
  void initState() {
    super.initState();
    TimelineRegistry.registerTabShell(this);
  }

  @override
  void dispose() {
    TimelineRegistry.unregisterTabShell(this);
    super.dispose();
  }

  List<_ShellTab> _builtinTabs(BuildContext context) => [
    _ShellTab(
      id: TimelineItemIds.photosTab,
      label: context.t.photos,
      icon: const Icon(Icons.photo_library_outlined),
      selectedIcon: Icon(Icons.photo_library, color: context.primaryColor),
      routeIndex: 0,
    ),
    _ShellTab(
      id: TimelineItemIds.albumsTab,
      label: context.t.albums,
      icon: const Icon(Icons.photo_album_outlined),
      selectedIcon: Icon(Icons.photo_album_rounded, color: context.primaryColor),
      routeIndex: 1,
    ),
    _ShellTab(
      id: TimelineItemIds.privateTab,
      label: 'Private',
      icon: const Icon(Icons.lock_outline),
      selectedIcon: Icon(Icons.lock, color: context.primaryColor),
      routeIndex: _privateTabIndex,
    ),
  ];

  /// Built-in and plugin tabs with the plugin rules of `tabShell.tabs` applied. Never empty.
  List<_ShellTab> _arrangeTabs(BuildContext context, TimelinePluginBridge bridge) {
    final builtins = _builtinTabs(context);
    final pluginTabs = bridge.tabs;
    final rules = bridge.rules(const [TimelineSlots.tabs]);
    if (pluginTabs.isEmpty && rules.isEmpty) {
      return builtins;
    }
    final extra = [
      for (final tab in pluginTabs)
        SlotExtraItem(
          id: tab.id,
          order: tab.order,
          item: _ShellTab(
            id: tab.id,
            label: tab.title,
            icon: Icon(tab.icon),
            selectedIcon: Icon(tab.selectedIcon ?? tab.icon, color: context.primaryColor),
            plugin: tab,
          ),
        ),
    ];
    final arranged = arrangeSlotItems<_ShellTab>(builtins, (tab) => tab.id, rules: rules, extra: extra);
    final tabs = arranged.isEmpty ? builtins : arranged;
    return [for (final tab in tabs) rules.rename[tab.id] == null ? tab : tab.relabel(rules.rename[tab.id]!)];
  }

  static const _builtinIds = [TimelineItemIds.photosTab, TimelineItemIds.albumsTab, TimelineItemIds.privateTab];

  String _currentId(TabsRouter router) =>
      _pluginTab ?? _builtinIds.elementAtOrNull(router.activeIndex) ?? TimelineItemIds.photosTab;

  /// Back from any tab but the first returns to the first one, like it always did: no haptics, no other effects.
  void _back(TabsRouter router, String firstId) {
    final tab = _tabs.where((tab) => tab.id == firstId).firstOrNull;
    final routeIndex = tab?.routeIndex;
    if (routeIndex == null) {
      _applySelection(router, firstId);
      return;
    }
    final previous = _currentId(router);
    if (_pluginTab != null) {
      setState(() => _pluginTab = null);
    }
    router.setActiveIndex(routeIndex);
    if (previous != firstId) {
      PluginHooks.emit(TimelineEvents.tabSelected, () => {'id': firstId, 'previous': previous});
    }
  }

  // ---- selection -------------------------------------------------------------------------------------------

  /// Selects tab [id] through the `tab.select` hook (plugins may cancel or redirect). Synchronous when no plugin
  /// hooks it. Returns false when there is no such tab.
  bool _selectTab(TabsRouter router, String id) {
    if (!_tabs.any((tab) => tab.id == id)) {
      return false;
    }
    if (!PluginHooks.has(TimelineHooks.selectTab)) {
      _applySelection(router, id);
      return true;
    }
    unawaited(_selectHooked(router, id));
    return true;
  }

  Future<void> _selectHooked(TabsRouter router, String id) async {
    try {
      final target = await PluginHooks.run<String>(
        TimelineHooks.selectTab,
        () => {'id': id, 'previous': _currentId(router)},
        () async => id,
        withArgs: (args) async => '${args['id'] ?? id}',
        encode: (value) => value,
        decode: (json) => json is String ? json : id,
      );
      if (mounted) {
        _applySelection(router, target);
      }
    } catch (error) {
      if (!PluginHooks.isCancelled(error)) {
        rethrow;
      }
      final message = PluginHooks.cancelMessage(error);
      if (message != null && message.isNotEmpty) {
        snackbar.show(message, SnackbarType.info);
      }
    }
  }

  void _applySelection(TabsRouter router, String id) {
    final tab = _tabs.where((tab) => tab.id == id).firstOrNull;
    if (tab == null) {
      return;
    }
    final previous = _currentId(router);
    final showingPrivate = _pluginTab == null && router.activeIndex == _privateTabIndex;

    final routeIndex = tab.routeIndex;
    if (routeIndex != null) {
      if (_pluginTab == null && router.activeIndex == kPhotoTabIndex && routeIndex == kPhotoTabIndex) {
        EventStream.shared.emit(const ScrollToTopEvent());
      }
      if (showingPrivate && routeIndex != _privateTabIndex) {
        ref.read(privateUnlockedProvider.notifier).state = false;
      }

      ref.read(hapticFeedbackProvider.notifier).selectionClick();
      if (_pluginTab != null) {
        setState(() => _pluginTab = null);
      }
      router.setActiveIndex(routeIndex);
      ref.read(tabProvider.notifier).state = routeIndex == kPhotoTabIndex ? TabEnum.home : TabEnum.albums;
    } else if (tab.plugin case final plugin?) {
      if (showingPrivate) {
        ref.read(privateUnlockedProvider.notifier).state = false;
      }
      ref.read(hapticFeedbackProvider.notifier).selectionClick();
      setState(() {
        _pluginTab = plugin.id;
        _openedPluginTabs[plugin.id] = plugin;
      });
    }

    if (previous != id) {
      PluginHooks.emit(TimelineEvents.tabSelected, () => {'id': id, 'previous': previous});
    }
  }

  // ---- TabShellHandle --------------------------------------------------------------------------------------

  @override
  List<Map<String, dynamic>> tabs() {
    final router = _router;
    final selected = router == null ? null : _currentId(router);
    return [
      for (final tab in _tabs)
        {'id': tab.id, 'title': tab.label, 'builtin': tab.plugin == null, 'selected': tab.id == selected},
    ];
  }

  @override
  String? get selectedTab {
    final router = _router;
    return router == null ? null : _currentId(router);
  }

  @override
  bool selectTab(String id) {
    final router = _router;
    return router != null && mounted && _selectTab(router, id);
  }

  // ---- build -------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isScreenLandscape = context.orientation == Orientation.landscape;
    final bridge = ref.watch(timelinePluginBridgeProvider);

    return AutoTabsRouter(
      routes: const [MainTimelineRoute(), LocalAlbumsRoute(), PrivateGalleryRoute()],
      duration: const Duration(milliseconds: 600),
      transitionBuilder: (context, child, animation) => FadeTransition(opacity: animation, child: child),
      builder: (context, child) {
        final tabsRouter = AutoTabsRouter.of(context);
        _router = tabsRouter;
        final tabs = _tabs = _arrangeTabs(context, bridge);

        // A plugin tab that went away (plugin disabled) falls back to the router's tab
        final pluginTab = _pluginTab;
        if (pluginTab != null && !tabs.any((tab) => tab.id == pluginTab)) {
          _pluginTab = null;
          _openedPluginTabs.remove(pluginTab);
        }
        final currentId = _currentId(tabsRouter);
        var selectedIndex = tabs.indexWhere((tab) => tab.id == currentId);
        if (selectedIndex < 0) {
          // The active built-in tab is hidden by a plugin: show the first tab instead
          selectedIndex = 0;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _applySelection(tabsRouter, _tabs.first.id);
            }
          });
        }
        final isFirstTab = selectedIndex == 0;
        void onSelected(int index) => _selectTab(tabsRouter, tabs[index].id);

        Widget navigationRail() {
          return NavigationRail(
            destinations: tabs
                .map(
                  (tab) =>
                      NavigationRailDestination(icon: tab.icon, label: Text(tab.label), selectedIcon: tab.selectedIcon),
                )
                .toList(),
            onDestinationSelected: onSelected,
            selectedIndex: selectedIndex,
            labelType: NavigationRailLabelType.all,
            groupAlignment: 0.0,
          );
        }

        final body = _openedPluginTabs.isEmpty ? child : _withPluginTabs(child);

        return PopScope(
          canPop: isFirstTab,
          onPopInvokedWithResult: (didPop, _) => !didPop ? _back(tabsRouter, tabs.first.id) : null,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: isScreenLandscape
                ? Row(
                    children: [
                      navigationRail(),
                      const VerticalDivider(),
                      Expanded(child: body),
                    ],
                  )
                : body,
            bottomNavigationBar: _BottomNavigationBar(
              selectedIndex: selectedIndex,
              onSelected: onSelected,
              destinations: [for (final tab in tabs) tab.destination],
            ),
          ),
        );
      },
    );
  }

  /// The router's tabs with the opened plugin tabs layered over them; only the selected one is visible and ticking.
  Widget _withPluginTabs(Widget routerChild) {
    final selected = _pluginTab;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: selected != null,
          child: TickerMode(enabled: selected == null, child: routerChild),
        ),
        for (final tab in _openedPluginTabs.values)
          Offstage(
            key: ValueKey(tab.id),
            offstage: selected != tab.id,
            child: TickerMode(
              enabled: selected == tab.id,
              child: Builder(builder: tab.builder),
            ),
          ),
      ],
    );
  }
}

class _BottomNavigationBar extends ConsumerStatefulWidget {
  const _BottomNavigationBar({required this.selectedIndex, required this.onSelected, required this.destinations});

  final List<Widget> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  ConsumerState createState() => _BottomNavigationBarState();
}

class _BottomNavigationBarState extends ConsumerState<_BottomNavigationBar> {
  bool hideNavigationBar = false;
  StreamSubscription? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _eventSubscription = EventStream.shared.listen<MultiSelectToggleEvent>(_onEvent);
  }

  void _onEvent(MultiSelectToggleEvent event) {
    setState(() {
      hideNavigationBar = event.isEnabled;
    });
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isScreenLandscape = context.orientation == Orientation.landscape;

    if (isScreenLandscape || hideNavigationBar) {
      return const SizedBox.shrink();
    }

    return NavigationBar(
      selectedIndex: widget.selectedIndex,
      onDestinationSelected: widget.onSelected,
      destinations: widget.destinations,
    );
  }
}
