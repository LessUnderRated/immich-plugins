import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/tab.provider.dart';
import 'package:immich_mobile/routing/router.dart';

@RoutePage()
class TabShellPage extends ConsumerStatefulWidget {
  const TabShellPage({super.key});

  @override
  ConsumerState<TabShellPage> createState() => _TabShellPageState();
}

class _TabShellPageState extends ConsumerState<TabShellPage> {
  @override
  Widget build(BuildContext context) {
    final isScreenLandscape = context.orientation == Orientation.landscape;

    final navigationDestinations = [
      NavigationDestination(
        label: context.t.photos,
        icon: const Icon(Icons.photo_library_outlined),
        selectedIcon: Icon(Icons.photo_library, color: context.primaryColor),
      ),
      NavigationDestination(
        label: context.t.albums,
        icon: const Icon(Icons.photo_album_outlined),
        selectedIcon: Icon(Icons.photo_album_rounded, color: context.primaryColor),
      ),
    ];

    Widget navigationRail(TabsRouter tabsRouter) {
      return NavigationRail(
        destinations: navigationDestinations
            .map(
              (e) => NavigationRailDestination(
                icon: e.icon,
                label: Text(e.label),
                selectedIcon: e.selectedIcon,
                disabled: !e.enabled,
              ),
            )
            .toList(),
        onDestinationSelected: (index) => _onNavigationSelected(tabsRouter, index, ref),
        selectedIndex: tabsRouter.activeIndex,
        labelType: NavigationRailLabelType.all,
        groupAlignment: 0.0,
      );
    }

    return AutoTabsRouter(
      routes: const [MainTimelineRoute(), LocalAlbumsRoute()],
      duration: const Duration(milliseconds: 600),
      transitionBuilder: (context, child, animation) => FadeTransition(opacity: animation, child: child),
      builder: (context, child) {
        final tabsRouter = AutoTabsRouter.of(context);
        return PopScope(
          canPop: tabsRouter.activeIndex == 0,
          onPopInvokedWithResult: (didPop, _) => !didPop ? tabsRouter.setActiveIndex(0) : null,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: isScreenLandscape
                ? Row(
                    children: [
                      navigationRail(tabsRouter),
                      const VerticalDivider(),
                      Expanded(child: child),
                    ],
                  )
                : child,
            bottomNavigationBar: _BottomNavigationBar(tabsRouter: tabsRouter, destinations: navigationDestinations),
          ),
        );
      },
    );
  }
}

void _onNavigationSelected(TabsRouter router, int index, WidgetRef ref) {
  if (router.activeIndex == kPhotoTabIndex && index == kPhotoTabIndex) {
    EventStream.shared.emit(const ScrollToTopEvent());
  }

  ref.read(hapticFeedbackProvider.notifier).selectionClick();
  router.setActiveIndex(index);
  ref.read(tabProvider.notifier).state = index == kPhotoTabIndex ? TabEnum.home : TabEnum.albums;
}

class _BottomNavigationBar extends ConsumerStatefulWidget {
  const _BottomNavigationBar({required this.tabsRouter, required this.destinations});

  final List<Widget> destinations;
  final TabsRouter tabsRouter;

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
      selectedIndex: widget.tabsRouter.activeIndex,
      onDestinationSelected: (index) => _onNavigationSelected(widget.tabsRouter, index, ref),
      destinations: widget.destinations,
    );
  }
}
