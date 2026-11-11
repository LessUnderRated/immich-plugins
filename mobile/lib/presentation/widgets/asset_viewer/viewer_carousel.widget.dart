import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';

final viewerCurrentIndexProvider = StateProvider<int>((ref) => 0);

class ViewerCarousel extends ConsumerStatefulWidget {
  const ViewerCarousel({super.key});

  static const double height = 56;

  @override
  ConsumerState<ViewerCarousel> createState() => _ViewerCarouselState();
}

class _ViewerCarouselState extends ConsumerState<ViewerCarousel> {
  static const double _itemWidth = 40;
  static const double _selectedWidth = 58;
  static const double _gap = 3;
  static const double _stride = _itemWidth + _gap;
  static const Size _decodeSize = Size(128, 128);

  late final ScrollController _controller = ScrollController(
    initialScrollOffset: ref.read(viewerCurrentIndexProvider) * _stride,
  );
  final Map<int, Future<BaseAsset?>> _pending = {};
  bool _dragging = false;
  int? _scrubIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int _indexAtOffset(TimelineService service) {
    if (!_controller.hasClients || service.totalAssets == 0) {
      return 0;
    }
    return (_controller.offset / _stride).round().clamp(0, service.totalAssets - 1);
  }

  void _requestPage(int index) {
    if (index == ref.read(viewerCurrentIndexProvider)) {
      return;
    }
    EventStream.shared.emit(ViewerJumpToIndexEvent(index));
  }

  void _centerOn(int index, {bool animate = true}) {
    if (!_controller.hasClients) {
      return;
    }
    final target = (index * _stride).clamp(0.0, _controller.position.maxScrollExtent);
    if ((target - _controller.offset).abs() < 0.5) {
      return;
    }
    if (animate) {
      unawaited(_controller.animateTo(target, duration: Durations.medium1, curve: Curves.easeOutCubic));
    } else {
      _controller.jumpTo(target);
    }
  }

  bool _onScroll(ScrollNotification notification, TimelineService service) {
    if (notification is ScrollStartNotification && notification.dragDetails != null) {
      _dragging = true;
    } else if (notification is ScrollUpdateNotification && _dragging) {
      final index = _indexAtOffset(service);
      if (index != _scrubIndex) {
        _scrubIndex = index;
        _requestPage(index);
      }
    } else if (notification is ScrollEndNotification && _dragging) {
      _dragging = false;
      _scrubIndex = null;
      final index = _indexAtOffset(service);
      _requestPage(index);
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerOn(index));
    }
    return false;
  }

  Future<BaseAsset?> _assetFuture(TimelineService service, int index) =>
      _pending.putIfAbsent(index, () => service.getAssetAsync(index));

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(timelineServiceProvider);
    final current = ref.watch(viewerCurrentIndexProvider);
    final total = service.totalAssets;

    ref.listen(viewerCurrentIndexProvider, (_, index) {
      if (!_dragging) {
        _centerOn(index);
      }
    });

    if (total <= 1) {
      return const SizedBox.shrink();
    }

    if (_pending.length > 200) {
      _pending.clear();
    }

    return SizedBox(
      height: ViewerCarousel.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sidePadding = (constraints.maxWidth - _selectedWidth) / 2;
          return NotificationListener<ScrollNotification>(
            onNotification: (notification) => _onScroll(notification, service),
            child: ListView.builder(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              padding: EdgeInsets.symmetric(horizontal: sidePadding),
              itemCount: total,
              itemBuilder: (context, index) {
                final selected = index == current;
                final cached = service.getAssetSafe(index);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _requestPage(index);
                    _centerOn(index);
                  },
                  child: AnimatedContainer(
                    duration: Durations.short3,
                    curve: Curves.easeOut,
                    width: selected ? _selectedWidth : _itemWidth,
                    margin: EdgeInsets.only(right: _gap, top: selected ? 0 : 6, bottom: selected ? 0 : 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(selected ? 6 : 3),
                      border: selected ? Border.all(color: Colors.white, width: 1.5) : null,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: cached != null
                        ? Thumbnail.fromAsset(asset: cached, size: _decodeSize)
                        : FutureBuilder<BaseAsset?>(
                            future: _assetFuture(service, index),
                            builder: (context, snapshot) => snapshot.data == null
                                ? const ColoredBox(color: Colors.white10)
                                : Thumbnail.fromAsset(asset: snapshot.data, size: _decodeSize),
                          ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
