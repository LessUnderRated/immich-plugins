/// Hide / order / rename rules for the built-in items of a slot, and the pure logic that applies them.
///
/// Plugins declare rules per slot in their manifest (`contributes.builtins.<slot>`); the kernel merges them across
/// plugins. This file has no Flutter dependency so widgets, host functions and tests can all use it.
library;

/// Prefix of plugin item ids in rules: `plugin:<plugin>/<id>`.
const builtinRulesPluginPrefix = 'plugin:';

/// Marks where the items an `order` list does not name go. Without it they follow the named ones.
const builtinRulesRest = '*';

/// Order of a plugin item without an explicit `order`: after every built-in.
const double builtinRulesLast = double.maxFinite;

/// The order a built-in item at [index] (as listed in the catalog) has when plugin items are placed among
/// built-ins by their numeric `order`: 100, 200, 300, ...
double builtinOrderOf(int index) => (index + 1) * 100.0;

class BuiltinItemRules {
  /// Ids of items that are not shown.
  final Set<String> hide;

  /// Ids in the order they are shown. Ids not listed go where [builtinRulesRest] is, or after the listed ones.
  final List<String> order;

  /// New labels by id.
  final Map<String, String> rename;

  const BuiltinItemRules({this.hide = const {}, this.order = const [], this.rename = const {}});

  static const none = BuiltinItemRules();

  bool get isEmpty => hide.isEmpty && order.isEmpty && rename.isEmpty;

  /// Reads `{ "hide": [ids], "order": [ids], "rename": { id: label } }`; anything malformed is ignored.
  factory BuiltinItemRules.fromJson(Object? json) {
    if (json is! Map) {
      return none;
    }
    final hide = json['hide'];
    final order = json['order'];
    final rename = json['rename'];
    return BuiltinItemRules(
      hide: hide is List ? {for (final id in hide) '$id'} : const {},
      order: order is List ? [for (final id in order) '$id'] : const [],
      rename: rename is Map
          ? {
              for (final MapEntry(:key, :value) in rename.entries)
                if (value is String) '$key': value,
            }
          : const {},
    );
  }

  Map<String, dynamic> toJson() => {'hide': hide.toList(), 'order': order, 'rename': rename};

  /// [other] applied over these rules: hidden ids add up, renames of [other] win, and the order of [other] wins when
  /// it has one.
  BuiltinItemRules merge(BuiltinItemRules other) {
    if (other.isEmpty) {
      return this;
    }
    if (isEmpty) {
      return other;
    }
    return BuiltinItemRules(
      hide: {...hide, ...other.hide},
      order: other.order.isNotEmpty ? other.order : order,
      rename: {...rename, ...other.rename},
    );
  }

  /// Merges the rules of several slots, the generic one first (`selection.actions`, then
  /// `selection.archive.actions`).
  static BuiltinItemRules mergeAll(Iterable<BuiltinItemRules> rules) => rules.fold(none, (a, b) => a.merge(b));

  bool isHidden(String id) => hide.contains(id);

  String labelOf(String id, String label) => rename[id] ?? label;
}

/// An item a plugin adds to a slot, placed among the built-ins by [order] (see [builtinOrderOf]).
class SlotExtraItem<T> {
  final String id;
  final T item;
  final double order;

  const SlotExtraItem({required this.id, required this.item, this.order = builtinRulesLast});
}

/// Applies [rules] to [builtins] (in catalog order) and merges [extra] plugin items in.
///
/// 1. Hidden ids are dropped (built-in and plugin items alike).
/// 2. Plugin items are placed among the built-ins by their numeric order (built-in `i` has `(i + 1) * 100`); equal
///    orders keep built-ins first, then plugin items in the order given.
/// 3. `rules.order` moves the ids it names to the front in that order, or around [builtinRulesRest] when it has one.
///
/// Returns [builtins] itself when there is nothing to change, so callers pay nothing without plugins.
List<T> arrangeSlotItems<T>(
  List<T> builtins,
  String? Function(T item) idOf, {
  BuiltinItemRules rules = BuiltinItemRules.none,
  List<SlotExtraItem<T>> extra = const [],
}) {
  if (rules.hide.isEmpty && rules.order.isEmpty && extra.isEmpty) {
    return builtins;
  }

  final entries = <({String? id, T item, double order, int seq})>[];
  var seq = 0;
  for (var index = 0; index < builtins.length; index++) {
    final item = builtins[index];
    entries.add((id: idOf(item), item: item, order: builtinOrderOf(index), seq: seq++));
  }
  for (final item in extra) {
    entries.add((id: item.id, item: item.item, order: item.order, seq: seq++));
  }
  entries.removeWhere((entry) => entry.id != null && rules.hide.contains(entry.id));
  if (extra.isNotEmpty) {
    // List.sort is not stable; the sequence number keeps equal orders in insertion order
    entries.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder != 0 ? byOrder : a.seq.compareTo(b.seq);
    });
  }

  final items = [for (final entry in entries) entry.item];
  if (rules.order.isEmpty) {
    return items;
  }
  return reorderByIds(items, idOf, rules.order);
}

/// Moves the items whose ids [order] names into that order; the others keep their relative order and go where
/// [builtinRulesRest] is, or after the named ones.
List<T> reorderByIds<T>(List<T> items, String? Function(T item) idOf, List<String> order) {
  final byId = <String, T>{};
  final rest = <T>[];
  final named = order.toSet();
  for (final item in items) {
    final id = idOf(item);
    if (id != null && named.contains(id) && !byId.containsKey(id)) {
      byId[id] = item;
    } else {
      rest.add(item);
    }
  }

  final result = <T>[];
  var restPlaced = false;
  for (final id in order) {
    if (id == builtinRulesRest) {
      if (!restPlaced) {
        result.addAll(rest);
        restPlaced = true;
      }
      continue;
    }
    final item = byId.remove(id);
    if (item != null) {
      result.add(item);
    }
  }
  if (!restPlaced) {
    result.addAll(rest);
  }
  return result;
}
