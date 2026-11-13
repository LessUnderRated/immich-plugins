import 'package:flutter/widgets.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/action_slots.dart';

/// The viewer's actions as plugins list and run them (`actions.list` / `actions.run` with surface `viewer`): the
/// top bar, the bottom bar and the ⋮ menu, in that order. The asset viewer registers [recorder] while it is open.
class ViewerActionSurface {
  static const _bars = ['topBar', 'bottomBar', 'menu'];

  final ActionSurfaceRecorder recorder;
  final _orders = <String, List<Object?>>{};

  ViewerActionSurface({required bool Function() isVisible})
    : recorder = ActionSurfaceRecorder(surface: 'viewer', isVisible: isVisible);

  /// The items of [bar] (`topBar`, `bottomBar` or `menu`) in display order; call it where the bar builds them.
  void setBarOrder(String bar, Iterable<Object?> items) {
    _orders[bar] = items.toList(growable: false);
    recorder.setOrder([for (final key in _bars) ...?_orders[key]]);
  }

  /// What action [id] resolved to (null when it does not apply), for items that are not `ActionWidget`s.
  void record(String id, ActionItem? item) => recorder.record(id, item);
}

/// Gives the viewer's bars their [ViewerActionSurface]. Sits next to the [ActionSurfaceScope] of its recorder.
class ViewerActionSurfaceScope extends InheritedWidget {
  final ViewerActionSurface surface;

  const ViewerActionSurfaceScope({super.key, required this.surface, required super.child});

  static ViewerActionSurface? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ViewerActionSurfaceScope>()?.surface;

  @override
  bool updateShouldNotify(ViewerActionSurfaceScope oldWidget) => !identical(surface, oldWidget.surface);
}
