import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_plugin.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/extensions/asyncvalue_extensions.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_registry.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/download_status_floating_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/general_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/multi_select_status_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_slots.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/scrubber.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/sliver_segmented_list.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_drag_selection.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline_pinch_zoom.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/providers/timeline/timeline_plugins.provider.dart';
import 'package:immich_mobile/routing/app_navigation_observer.dart';
import 'package:immich_mobile/utils/debounce.dart';
import 'package:immich_mobile/widgets/common/immich_sliver_app_bar.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';
import 'package:immich_mobile/widgets/common/selection_sliver_app_bar.dart';

class Timeline extends ConsumerWidget {
  const Timeline({
    super.key,
    this.topSliverWidget,
    this.topSliverWidgetHeight,
    this.bottomSliverWidget,
    this.showStorageIndicator = false,
    this.withStack = false,
    this.appBar = const ImmichSliverAppBar(floating: true, pinned: false, snap: false),
    this.bottomSheet = const GeneralBottomSheet(minChildSize: 0.23),
    this.groupBy,
    this.withScrubber = true,
    this.snapToMonth = true,
    this.readOnly = false,
    this.persistentBottomBar = false,
    this.loadingWidget,
    this.page,
  });

  /// Page id of the timeline (`mainTimeline`, `archive`, ...; see `TimelinePages`): names its plugin slots
  /// (`<page>.header`, `.footer`, `.empty`, `.body`) and is passed to tile, header and hook contexts.
  final String? page;

  final Widget? topSliverWidget;
  final double? topSliverWidgetHeight;
  final Widget? bottomSliverWidget;
  final bool showStorageIndicator;
  final Widget? appBar;
  final Widget? bottomSheet;
  final bool withStack;
  final GroupAssetsBy? groupBy;
  final bool withScrubber;
  final bool snapToMonth;
  final bool readOnly;
  final bool persistentBottomBar;
  final Widget? loadingWidget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final columnCount = ref.watch(appConfigProvider.select((config) => config.timeline.tilesPerRow));
    return LayoutBuilder(
      builder: (_, constraints) {
        return ProviderScope(
          overrides: [
            // overrideWithValue keeps the scoped args in sync with the latest constraints on rebuilds,
            // a function override would stay locked to the first frame's constraints for the whole session
            timelineArgsProvider.overrideWithValue(
              TimelineArgs(
                maxWidth: constraints.maxWidth,
                maxHeight: constraints.maxHeight,
                columnCount: columnCount,
                showStorageIndicator: showStorageIndicator,
                withStack: withStack,
                groupBy: groupBy,
              ),
            ),
            if (readOnly) readonlyModeProvider.overrideWith(() => _AlwaysReadOnlyNotifier()),
          ],
          child: _SliverTimeline(
            page: page ?? TimelinePages.timeline,
            topSliverWidget: topSliverWidget,
            topSliverWidgetHeight: topSliverWidgetHeight,
            bottomSliverWidget: bottomSliverWidget,
            appBar: appBar,
            bottomSheet: bottomSheet,
            withScrubber: withScrubber,
            persistentBottomBar: persistentBottomBar,
            snapToMonth: snapToMonth,
            maxWidth: constraints.maxWidth,
            loadingWidget: loadingWidget,
          ),
        );
      },
    );
  }
}

class _AlwaysReadOnlyNotifier extends ReadOnlyModeNotifier {
  @override
  bool build() => true;

  @override
  void setReadonlyMode(bool value) {}

  @override
  void toggleReadonlyMode() {}
}

class _SliverTimeline extends ConsumerStatefulWidget {
  const _SliverTimeline({
    required this.page,
    this.topSliverWidget,
    this.topSliverWidgetHeight,
    this.bottomSliverWidget,
    this.appBar,
    this.bottomSheet,
    this.withScrubber = true,
    this.persistentBottomBar = false,
    this.snapToMonth = true,
    this.maxWidth,
    this.loadingWidget,
  });

  final Widget? topSliverWidget;
  final double? topSliverWidgetHeight;
  final Widget? bottomSliverWidget;
  final Widget? appBar;
  final Widget? bottomSheet;
  final bool withScrubber;
  final bool persistentBottomBar;
  final bool snapToMonth;
  final double? maxWidth;
  final Widget? loadingWidget;
  final String page;

  @override
  ConsumerState createState() => _SliverTimelineState();
}

class _SliverTimelineState extends ConsumerState<_SliverTimeline>
    with WidgetsBindingObserver
    implements TimelineHandle {
  late final ScrollController _scrollController;
  final _segmentedListKey = GlobalKey();
  StreamSubscription? _eventSubscription;

  int? _restoreAssetIndex;

  final Debouncer _fastScrollDebouncer = Debouncer(interval: const Duration(milliseconds: 100));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController = ScrollController(onAttach: _restoreAssetPosition);
    _eventSubscription = EventStream.shared.listen(_onEvent);

    ref.listenManual(multiSelectProvider.select((s) => s.isEnabled), _onMultiSelectionToggled);
    ref.listenManual(multiSelectProvider, _onSelectionChanged);
    TimelineRegistry.registerTimeline(this);
  }

  @override
  void didUpdateWidget(covariant _SliverTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.maxWidth != oldWidget.maxWidth) {
      // The updated args already regenerate the segments, only remember the scroll position to restore it afterwards
      final segments = ref.read(timelineSegmentProvider).valueOrNull;
      if (segments != null && _scrollController.hasClients) {
        _restoreAssetIndex = _getCurrentAssetIndex(segments);
      }
    }
  }

  // Capture iOS status bar tap
  @override
  void handleStatusBarTap() {
    // Routes may be pushed non-opaquely on top of the timeline (such as the asset viewer), or the timeline
    // may be in a background tab. In either case, `handleStatusBarTap()` still fires
    // Make sure the timeline is the primary route before scrolling to the top
    final routeData = context.findAncestorWidgetOfExactType<RouteDataScope>()?.routeData;
    // The tap is generated async, so it can arrive after a route pop has started (due to a back button or similar)
    // Check if route is alive and not exiting before taking action
    final observers = Navigator.maybeOf(context)?.widget.observers ?? const <NavigatorObserver>[];
    final isRouteTransitioning = observers.whereType<TransitioningRouteObserver>().any(
      (observer) => observer.hasTransitioningRoute,
    );

    if (ModalRoute.of(context)?.isCurrent == true && routeData?.isActive == true && !isRouteTransitioning) {
      _scrollToTop();
    }
  }

  void _onEvent(Event event) {
    switch (event) {
      case ScrollToTopEvent():
        _scrollToTop();
      case final ScrollToDateEvent scrollToDateEvent:
        _scrollToDate(scrollToDateEvent.date);
      case ViewerClosedEvent(:final asset):
        final routeData = context.findAncestorWidgetOfExactType<RouteDataScope>()?.routeData;
        final index = ref.read(timelineServiceProvider).getIndex(asset.heroTag);
        if (routeData != null && routeData.router.root.topRoute == routeData && index != null) {
          _scrollToAssetIfOffScreen(index);
        }
      case TimelineReloadEvent():
        setState(() {});
      default:
        break;
    }
  }

  void _restoreAssetPosition(_) {
    if (_restoreAssetIndex == null) {
      return;
    }

    final asyncSegments = ref.read(timelineSegmentProvider);
    asyncSegments.whenData((segments) {
      final targetOffset = _getAssetRowPosition(segments, _restoreAssetIndex!)?.top;
      if (targetOffset != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scrollController.jumpTo(targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent));
          }
        });
      }
    });
    _restoreAssetIndex = null;
  }

  ({double top, double bottom})? _getAssetRowPosition(List<Segment> segments, int assetIndex) {
    final targetSegment = segments.firstWhereOrNull(
      (segment) => assetIndex < segment.firstAssetIndex + segment.bucket.assetCount,
    );
    if (targetSegment == null) {
      return null;
    }

    final assetIndexInSegment = assetIndex - targetSegment.firstAssetIndex;
    final columnCount = ref.read(timelineArgsProvider).columnCount;
    final rowIndexInSegment = (assetIndexInSegment / columnCount).floor();
    final targetRowIndex = targetSegment.firstIndex + 1 + rowIndexInSegment;
    return (
      top: targetSegment.indexToLayoutOffset(targetRowIndex),
      bottom: targetSegment.indexToLayoutOffset(targetRowIndex + 1) - targetSegment.spacing,
    );
  }

  void _scrollToAssetIfOffScreen(int index) {
    final row = _getAssetRowPosition(ref.read(timelineSegmentProvider).valueOrNull ?? const [], index);
    if (row == null) {
      return;
    }

    final list = _segmentedListKey.currentContext?.findRenderObject() as RenderSliver?;
    if (list == null) {
      return;
    }

    final position = _scrollController.position;
    final topInset = math.max(list.constraints.overlap, context.padding.top);
    final bottomInset = context.padding.bottom;
    final top = list.constraints.precedingScrollExtent + row.top;
    final visibleTop = position.pixels + topInset;
    final bottom = list.constraints.precedingScrollExtent + row.bottom;
    final visibleBottom = position.pixels + position.viewportDimension - bottomInset;
    if (top >= visibleTop && bottom <= visibleBottom) {
      return;
    }

    final target = top < visibleTop ? top - topInset : bottom - position.viewportDimension + bottomInset;
    _scrollController.jumpTo(target.clamp(0.0, position.maxScrollExtent));
  }

  void _onMultiSelectionToggled(_, bool isEnabled) {
    EventStream.shared.emit(MultiSelectToggleEvent(isEnabled));
  }

  void _onSelectionChanged(MultiSelectState? previous, MultiSelectState next) {
    if (previous?.selectedAssets == next.selectedAssets) {
      return;
    }
    PluginHooks.emit(TimelineEvents.selectionChanged, () => {'page': widget.page, 'origin': origin, ...selection()});
  }

  int? _getCurrentAssetIndex(List<Segment> segments) {
    final currentOffset = _scrollController.offset.clamp(0.0, _scrollController.position.maxScrollExtent);
    final segment = segments.findByOffset(currentOffset) ?? segments.lastOrNull;
    int? targetAssetIndex;
    if (segment != null) {
      final rowIndex = segment.getMinChildIndexForScrollOffset(currentOffset);
      if (rowIndex > segment.firstIndex) {
        final rowIndexInSegment = rowIndex - (segment.firstIndex + 1);
        final assetsPerRow = ref.read(timelineArgsProvider).columnCount;
        final assetIndexInSegment = rowIndexInSegment * assetsPerRow;
        targetAssetIndex = segment.firstAssetIndex + assetIndexInSegment;
      } else {
        targetAssetIndex = segment.firstAssetIndex;
      }
    }
    return targetAssetIndex;
  }

  @override
  void dispose() {
    TimelineRegistry.unregisterTimeline(this);
    WidgetsBinding.instance.removeObserver(this);
    _fastScrollDebouncer.dispose();
    _scrollController.dispose();
    unawaited(_eventSubscription?.cancel());
    super.dispose();
  }

  /// Track whether the timeline is moving fast enough to defer per-row asset loading
  bool _onScrollVelocityNotification(ScrollNotification notification) {
    // Only consider the primary timeline ScrollView (no nested views) and update events
    if (notification.depth != 0 || notification is! ScrollUpdateNotification) {
      return false;
    }

    // Use Flutter's built in fast velocity tracking
    _emitScrolled();

    if (_scrollController.position.recommendDeferredLoading(context)) {
      ref.read(timelineStateProvider.notifier).setRecommendDeferredLoading(true);

      // We cannot rely on scroll end events, as the timeline scrubber jumps from position
      // to position, resulting in large spikes in velocity followed by low velocity
      _fastScrollDebouncer.run(() => ref.read(timelineStateProvider.notifier).setRecommendDeferredLoading(false));
    }
    return false;
  }

  void _scrollToTop() {
    if (!_scrollController.hasClients) {
      return;
    }

    _scrollController.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeInOut);
  }

  bool _scrollToDate(DateTime date) {
    var found = false;
    final asyncSegments = ref.read(timelineSegmentProvider);
    asyncSegments.whenData((segments) {
      // Find the segment that contains assets from the target date
      final targetSegment = segments.firstWhereOrNull((segment) {
        if (segment.bucket is TimeBucket) {
          final segmentDate = (segment.bucket as TimeBucket).date;
          // Check if the segment date matches the target date (year, month, day)
          return segmentDate.year == date.year && segmentDate.month == date.month && segmentDate.day == date.day;
        }
        return false;
      });

      // If exact date not found, try to find the closest month
      final fallbackSegment =
          targetSegment ??
          segments.firstWhereOrNull((segment) {
            if (segment.bucket is TimeBucket) {
              final segmentDate = (segment.bucket as TimeBucket).date;
              return segmentDate.year == date.year && segmentDate.month == date.month;
            }
            return false;
          });

      if (fallbackSegment != null) {
        found = true;
        // Scroll to the segment with a small offset to show the header
        final targetOffset = fallbackSegment.startOffset - 50;
        _scrollController.animateTo(
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
      }
    });
    return found;
  }

  // ---- plugin access (TimelineHandle) ------------------------------------------------------------------------

  DateTime _lastScrolledEvent = DateTime.fromMillisecondsSinceEpoch(0);

  void _emitScrolled() {
    if (!PluginHooks.listens(TimelineEvents.scrolled)) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastScrolledEvent) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastScrolledEvent = now;
    final range = _visibleIndexes();
    PluginHooks.emit(
      TimelineEvents.scrolled,
      () => {
        'page': widget.page,
        'origin': origin,
        'firstIndex': range?.first,
        'lastIndex': range?.last,
        'total': totalAssets,
      },
    );
  }

  @override
  String get page => widget.page;

  @override
  String get origin => ref.read(timelineServiceProvider).origin.name;

  @override
  bool get isVisible => mounted && (ModalRoute.of(context)?.isCurrent ?? true) && TickerMode.valuesOf(context).enabled;

  @override
  int get totalAssets => ref.read(timelineServiceProvider).totalAssets;

  @override
  Future<void> refresh() => ref.read(timelineServiceProvider).refresh();

  @override
  Future<bool> scrollToAsset(String assetId) async {
    final service = ref.read(timelineServiceProvider);
    final assets = await service.loadAssets(0, service.totalAssets);
    final index = assets.indexWhere((asset) => TimelineAssetJson.matches(asset, assetId));
    return index >= 0 && await scrollToIndex(index);
  }

  @override
  Future<bool> scrollToIndex(int index) async {
    if (!mounted || index < 0 || index >= totalAssets || !_scrollController.hasClients) {
      return false;
    }
    final segments = ref.read(timelineSegmentProvider).valueOrNull;
    if (segments == null || _getAssetRowPosition(segments, index) == null) {
      return false;
    }
    _scrollToAssetIfOffScreen(index);
    return true;
  }

  @override
  Future<bool> scrollToDate(DateTime date) async => mounted && _scrollToDate(date);

  /// First and last asset index on screen.
  ({int first, int last})? _visibleIndexes() {
    final segments = ref.read(timelineSegmentProvider).valueOrNull;
    final total = totalAssets;
    if (segments == null || segments.isEmpty || total == 0 || !_scrollController.hasClients) {
      return null;
    }
    final list = _segmentedListKey.currentContext?.findRenderObject() as RenderSliver?;
    final preceding = list?.constraints.precedingScrollExtent ?? 0;
    final position = _scrollController.position;
    final columnCount = ref.read(timelineArgsProvider).columnCount;

    int indexAt(double offset) {
      final clamped = offset.clamp(0.0, segments.last.endOffset);
      final segment = segments.findByOffset(clamped) ?? segments.last;
      final rowIndex = segment.getMinChildIndexForScrollOffset(clamped);
      if (rowIndex <= segment.firstIndex) {
        return segment.firstAssetIndex;
      }
      return segment.firstAssetIndex + (rowIndex - segment.firstIndex - 1) * columnCount;
    }

    final first = indexAt(position.pixels - preceding);
    final last = math.min(
      total - 1,
      indexAt(position.pixels + position.viewportDimension - preceding) + columnCount - 1,
    );
    return (first: math.min(first, last), last: last);
  }

  @override
  Future<Map<String, dynamic>> visibleRange() async {
    final range = _visibleIndexes();
    final service = ref.read(timelineServiceProvider);
    final assets = range == null ? const [] : await service.loadAssets(range.first, range.last - range.first + 1);
    return {
      'page': widget.page,
      'origin': service.origin.name,
      'firstIndex': range?.first,
      'lastIndex': range?.last,
      'total': service.totalAssets,
      'assetIds': [for (final asset in assets) asset.id],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> assets(int offset, int limit) async {
    final service = ref.read(timelineServiceProvider);
    final count = math.min(limit, service.totalAssets - offset);
    if (count <= 0) {
      return const [];
    }
    return TimelineAssetJson.encodeAll(await service.loadAssets(offset, count));
  }

  @override
  Map<String, dynamic> selection() {
    final state = ref.read(multiSelectProvider);
    return {
      'enabled': state.isEnabled || state.forceEnable,
      'count': state.selectedAssets.length,
      'assetIds': [for (final asset in state.selectedAssets) asset.id],
    };
  }

  @override
  Future<int> select(List<String> assetIds, SelectionChange change) async {
    final notifier = ref.read(multiSelectProvider.notifier);
    final current = ref.read(multiSelectProvider).selectedAssets;
    bool named(BaseAsset asset) => assetIds.any((id) => TimelineAssetJson.matches(asset, id));
    switch (change) {
      case SelectionChange.remove:
        notifier.replaceSelection(remove: current.where(named).toList(), add: const []);
      case SelectionChange.add || SelectionChange.set:
        final service = ref.read(timelineServiceProvider);
        final found = (await service.loadAssets(0, service.totalAssets)).where(named).toList();
        if (!mounted) {
          return 0;
        }
        notifier.replaceSelection(remove: change == SelectionChange.set ? current : const [], add: found);
    }
    return ref.read(multiSelectProvider).selectedAssets.length;
  }

  @override
  void clearSelection() {
    final state = ref.read(multiSelectProvider);
    final notifier = ref.read(multiSelectProvider.notifier);
    if (state.forceEnable) {
      notifier.replaceSelection(remove: state.selectedAssets, add: const []);
    } else {
      notifier.reset();
    }
  }

  @override
  Future<int> selectAll() async {
    await ref.read(multiSelectProvider.notifier).selectAll(ref.read(timelineServiceProvider));
    return mounted ? ref.read(multiSelectProvider).selectedAssets.length : 0;
  }

  @override
  Widget build(BuildContext _) {
    final bridge = ref.watch(timelinePluginBridgeProvider);
    final asyncSegments = ref.watch(timelineSegmentProvider);
    final maxHeight = ref.watch(timelineArgsProvider.select((args) => args.maxHeight));
    final isSelectionMode = ref.watch(multiSelectProvider.select((s) => s.forceEnable));
    final isMultiSelectEnabled = ref.watch(multiSelectProvider.select((s) => s.isEnabled));
    final isMultiSelectStatusVisible = !isSelectionMode && isMultiSelectEnabled;
    final isBottomWidgetVisible =
        widget.bottomSheet != null && (isMultiSelectStatusVisible || widget.persistentBottomBar);
    final smoothScrubbing = ref.watch(appConfigProvider.select((config) => config.timeline.smoothScrubbing));
    final snapToMonth = widget.snapToMonth && !smoothScrubbing;

    return PopScope(
      canPop: !isMultiSelectEnabled,
      onPopInvokedWithResult: (_, _) {
        if (isMultiSelectEnabled) {
          ref.read(multiSelectProvider.notifier).reset();
        }
      },
      child: BackButtonListener(
        onBackButtonPressed: () async {
          if (!isMultiSelectEnabled) {
            return false;
          }
          ref.read(multiSelectProvider.notifier).reset();
          return true;
        },
        child: PrimaryScrollController(
          controller: _scrollController,
          child: Scaffold(
            // This removes the built in Scaffold `handleStatusBarTap` implementation, preventing duplicate
            // events when we provide our own
            primary: false,
            resizeToAvoidBottomInset: false,
            floatingActionButton: switch (timelineSlotContent(bridge, [
              TimelineSlots.fab(widget.page),
            ], () => {'page': widget.page, 'origin': origin})) {
              final Widget fab => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [fab, const DownloadStatusFloatingButton()],
              ),
              null => const DownloadStatusFloatingButton(),
            },
            body: asyncSegments.widgetWhen(
              onLoading: widget.loadingWidget != null ? () => widget.loadingWidget! : null,
              onData: (segments) {
                final childCount = (segments.lastOrNull?.lastIndex ?? -1) + 1;
                final page = widget.page;
                Map<String, dynamic> slotContext() => {
                  'page': page,
                  'origin': origin,
                  'total': totalAssets,
                  'selectionCount': ref.read(multiSelectProvider).selectedAssets.length,
                };
                final header = timelineSlotContent(bridge, [
                  TimelineSlots.header(page),
                  TimelineSlots.timelineHeader,
                ], slotContext);
                final footer = timelineSlotContent(bridge, [
                  TimelineSlots.footer(page),
                  TimelineSlots.timelineFooter,
                ], slotContext);
                final empty = childCount == 0
                    ? timelineSlotContent(bridge, [TimelineSlots.empty(page), TimelineSlots.timelineEmpty], slotContext)
                    : null;
                final double appBarExpandedHeight = widget.appBar != null && widget.appBar is MesmerizingSliverAppBar
                    ? 200
                    : 0;
                final topPadding = context.padding.top + (widget.appBar == null ? 0 : kToolbarHeight) + 10;

                const bottomSheetOpenModifier = 120.0;
                final contentBottomPadding =
                    context.padding.bottom + (isMultiSelectEnabled ? bottomSheetOpenModifier : 0);
                final scrubberBottomPadding = contentBottomPadding + kScrubberThumbHeight;

                final body = TimelinePinchZoom(
                  onColumnCountWillChange: () {
                    final targetAssetIndex = _getCurrentAssetIndex(segments);
                    setState(() {
                      _restoreAssetIndex = targetAssetIndex;
                    });
                  },
                  child: TimelineDragSelection(
                    builder: (physics) {
                      final grid = CustomScrollView(
                        primary: true,
                        physics: physics,
                        scrollCacheExtent: .pixels(maxHeight * 2),
                        slivers: [
                          if (isSelectionMode)
                            const SelectionSliverAppBar()
                          else if (widget.appBar != null)
                            widget.appBar!,
                          if (widget.topSliverWidget != null) widget.topSliverWidget!,
                          if (header != null) SliverToBoxAdapter(child: header),
                          if (empty != null) SliverFillRemaining(hasScrollBody: false, child: empty),
                          SliverSegmentedList(
                            key: _segmentedListKey,
                            segments: segments,
                            delegate: SliverChildBuilderDelegate(
                              (ctx, index) {
                                if (index >= childCount) {
                                  return null;
                                }
                                final segment = segments.findByIndex(index);
                                return segment?.builder(ctx, index) ?? const SizedBox.shrink();
                              },
                              childCount: childCount,
                              addAutomaticKeepAlives: false,
                              // We add repaint boundary around tiles, so skip the auto boundaries
                              addRepaintBoundaries: false,
                            ),
                          ),
                          if (widget.bottomSliverWidget != null) widget.bottomSliverWidget!,
                          if (footer != null) SliverToBoxAdapter(child: footer),
                          SliverPadding(padding: EdgeInsets.only(bottom: contentBottomPadding)),
                        ],
                      );

                      final Widget timeline;
                      if (widget.withScrubber) {
                        timeline = Scrubber(
                          snapToMonth: snapToMonth,
                          layoutSegments: segments,
                          timelineHeight: maxHeight,
                          topPadding: topPadding,
                          bottomPadding: scrubberBottomPadding,
                          monthSegmentSnappingOffset: widget.topSliverWidgetHeight ?? 0 + appBarExpandedHeight,
                          hasAppBar: widget.appBar != null,
                          child: grid,
                        );
                      } else {
                        timeline = grid;
                      }

                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          NotificationListener<ScrollNotification>(
                            onNotification: _onScrollVelocityNotification,
                            child: timeline,
                          ),
                          if (isBottomWidgetVisible)
                            Positioned(
                              top: MediaQuery.paddingOf(context).top,
                              left: 25,
                              child: const SizedBox(
                                height: kToolbarHeight,
                                child: Center(child: MultiSelectStatusButton()),
                              ),
                            ),
                          if (isBottomWidgetVisible) widget.bottomSheet!,
                        ],
                      );
                    },
                  ),
                );
                final bodySlot = TimelineSlots.body(page);
                return TimelinePageScope(
                  page: page,
                  child: bridge.hasDecorations(bodySlot) ? bridge.decorate(bodySlot, slotContext(), body) : body,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
