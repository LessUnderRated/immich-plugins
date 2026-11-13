import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/builtin_rules.dart';

/// A built-in (or plugin) item of a viewer slot with its stable id.
///
/// [id] is the catalog id (`dateTime`, `carousel`, ...) or `plugin:<plugin>/<id>`; null marks an item that rules
/// cannot hide or move.
class ViewerSlotItem<T> {
  final String? id;
  final T value;

  const ViewerSlotItem(this.id, this.value);
}

/// Applies the plugins' hide / order [rules] of a slot to [items] and merges [extra] plugin items in.
///
/// Returns the values in display order. Without rules and extras this is the input order, so the built-in
/// behaviour is unchanged when no plugin touches the slot.
List<T> arrangeViewerItems<T>(
  List<ViewerSlotItem<T>> items, {
  required BuiltinItemRules rules,
  List<SlotExtraItem<ViewerSlotItem<T>>> extra = const [],
}) {
  if (rules.isEmpty && extra.isEmpty) {
    return [for (final item in items) item.value];
  }
  final arranged = arrangeSlotItems<ViewerSlotItem<T>>(items, (item) => item.id, rules: rules, extra: extra);
  return [for (final item in arranged) item.value];
}
