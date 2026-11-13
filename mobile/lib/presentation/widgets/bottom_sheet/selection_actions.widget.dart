import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_registry.dart';
import 'package:immich_mobile/presentation/actions/action_ids.dart';
import 'package:immich_mobile/presentation/actions/action_slots.dart';

/// The actions of a selection sheet or bar named [sheet] (see `SelectionSheets`).
///
/// Applies the plugin rules of `selection.actions` and `selection.<sheet>.actions` to [actions], merges plugin
/// actions in, and makes the result listable and runnable by plugins (`actions.list`, `actions.run` with surface
/// `selection`). [builder] lays the arranged widgets out.
class SelectionActions extends ConsumerStatefulWidget {
  final String sheet;
  final List<Widget> actions;
  final Widget Function(BuildContext context, List<Widget> actions) builder;

  const SelectionActions({super.key, required this.sheet, required this.actions, required this.builder});

  @override
  ConsumerState<SelectionActions> createState() => _SelectionActionsState();
}

class _SelectionActionsState extends ConsumerState<SelectionActions> {
  late final ActionSurfaceRecorder _recorder = ActionSurfaceRecorder(
    surface: 'selection',
    isVisible: () => mounted && (ModalRoute.of(context)?.isCurrent ?? true) && TickerMode.valuesOf(context).enabled,
    useAssets: (assetIds) async {
      await TimelineRegistry.activeTimeline?.select(assetIds, SelectionChange.set);
      await nextFrame();
    },
  );

  @override
  void initState() {
    super.initState();
    TimelineRegistry.registerSurface(_recorder);
  }

  @override
  void dispose() {
    TimelineRegistry.unregisterSurface(_recorder);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final actions = arrangeActionWidgets(ref, ActionSlots.selectionSlots(widget.sheet), widget.actions);
    _recorder.setOrder(actions);
    return ActionSurfaceScope(recorder: _recorder, child: widget.builder(context, actions));
  }
}
