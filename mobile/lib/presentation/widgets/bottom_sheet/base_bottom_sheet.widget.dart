import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_mobile/presentation/actions/action_ids.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/selection_actions.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/providers/timeline/timeline_plugins.provider.dart';

class BaseBottomSheet extends ConsumerStatefulWidget {
  final List<Widget> actions;
  final DraggableScrollableController? controller;
  final List<Widget>? slivers;
  final Widget? footer;
  final double initialChildSize;
  final double minChildSize;
  final double maxChildSize;
  final bool expand;
  final bool shouldCloseOnMinExtent;
  final bool resizeOnScroll;
  final Color? backgroundColor;

  /// Name of the selection sheet (see `SelectionSheets`). When set, plugins can hide, reorder and rename [actions],
  /// add their own actions and sections (`selection.sections`), and hide the built-in album section ([slivers], id
  /// `addToAlbum`).
  final String? sheet;

  const BaseBottomSheet({
    super.key,
    required this.actions,
    this.slivers,
    this.footer,
    this.controller,
    this.initialChildSize = 0.35,
    double? minChildSize,
    this.maxChildSize = 0.65,
    this.expand = true,
    this.shouldCloseOnMinExtent = true,
    this.resizeOnScroll = true,
    this.backgroundColor,
    this.sheet,
  }) : minChildSize = minChildSize ?? 0.15;

  @override
  ConsumerState<BaseBottomSheet> createState() => _BaseDraggableScrollableSheetState();
}

class _BaseDraggableScrollableSheetState extends ConsumerState<BaseBottomSheet> {
  late DraggableScrollableController _controller;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? DraggableScrollableController();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(timelineStateProvider, (previous, next) {
      if (!widget.resizeOnScroll) {
        return;
      }

      if (previous?.isInteracting != true && next.isInteracting) {
        unawaited(
          _controller.animateTo(
            widget.minChildSize,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
          ),
        );
      }
    });

    final sheet = widget.sheet;
    final bridge = sheet == null ? null : ref.watch(timelinePluginBridgeProvider);
    final hideAlbums =
        bridge != null && bridge.rules(const [ActionSlots.selectionSections]).isHidden(TimelineItemIds.addToAlbum);
    final slivers = hideAlbums ? null : widget.slivers;
    final sections = bridge != null && bridge.hasContent(ActionSlots.selectionSections)
        ? bridge.content(ActionSlots.selectionSections, {
            'sheet': sheet,
            'selectionCount': ref.read(multiSelectProvider).selectedAssets.length,
          })
        : null;

    Widget actionRow(List<Widget> actions) => Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: actions),
        ),
        const Divider(indent: 16, endIndent: 16),
        const SizedBox(height: 16),
      ],
    );

    return DraggableScrollableSheet(
      controller: _controller,
      initialChildSize: widget.initialChildSize,
      minChildSize: widget.minChildSize,
      maxChildSize: widget.maxChildSize,
      snap: false,
      expand: widget.expand,
      shouldCloseOnMinExtent: widget.shouldCloseOnMinExtent,
      builder: (BuildContext context, ScrollController scrollController) {
        return Card(
          color: widget.backgroundColor ?? context.colorScheme.surfaceContainer,
          elevation: 3.0,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  controller: scrollController,
                  slivers: [
                    const SliverToBoxAdapter(child: _DragHandle()),
                    if (sheet != null)
                      SliverToBoxAdapter(
                        child: SelectionActions(
                          sheet: sheet,
                          actions: widget.actions,
                          builder: (context, actions) => actions.isEmpty ? const SizedBox.shrink() : actionRow(actions),
                        ),
                      )
                    else if (widget.actions.isNotEmpty)
                      SliverToBoxAdapter(child: actionRow(widget.actions)),
                    if (sections != null) SliverToBoxAdapter(child: sections),
                    ...?slivers,
                  ],
                ),
              ),
              if (widget.footer != null) widget.footer!,
            ],
          ),
        );
      },
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: Center(
        child: SizedBox(
          width: 32,
          height: 6,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(20)),
              color: context.themeData.dividerColor.lighten(amount: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}
