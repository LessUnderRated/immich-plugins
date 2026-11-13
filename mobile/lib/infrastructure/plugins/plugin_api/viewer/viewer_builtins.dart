import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/builtin_rules.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_bridge.dart';

/// A built-in (or plugin) item of a viewer slot with its stable id.
///
/// [id] is the catalog id (`favorite`, `share`, ...) or `plugin:<plugin>/<id>`; null marks an item that rules cannot
/// hide or move (e.g. a group of legacy plugin buttons).
class ViewerSlotItem<T> {
  final String? id;
  final T value;

  const ViewerSlotItem(this.id, this.value);
}

/// Applies the plugins' hide / order rules of [slotId] to [items] and merges [extra] plugin items in.
///
/// Returns the values in display order. Without rules and extras this is the input order, so the built-in
/// behaviour is unchanged when no plugin touches the slot.
List<T> arrangeViewerItems<T>(
  String slotId,
  List<ViewerSlotItem<T>> items, {
  List<SlotExtraItem<ViewerSlotItem<T>>> extra = const [],
  BuiltinItemRules? rules,
}) {
  final arranged = arrangeSlotItems<ViewerSlotItem<T>>(
    items,
    (item) => item.id,
    rules: rules ?? ViewerPlugins.rules(slotId),
    extra: extra,
  );
  return [for (final item in arranged) item.value];
}

/// The label of built-in item [id] in [slotId] after plugin renames.
String viewerItemLabel(String slotId, String id, String label) => ViewerPlugins.rules(slotId).labelOf(id, label);
