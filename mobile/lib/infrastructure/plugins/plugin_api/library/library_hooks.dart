import 'dart:async';

import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';

/// A built-in item of a library slot with its catalog id (`libraryBuiltins`).
typedef LibrarySlotItem<T> = ({String id, T item});

/// Hook, query and event plumbing of the library area.
///
/// Every library page runs its built-in actions, list queries and events through this class, so they reach the
/// plugin kernel through the [PluginHooks] binding. Everything is free while no plugin uses a hook or event: actions
/// call the original directly, queries return the input list itself (synchronously) and events build nothing.
abstract final class LibraryPluginHooks {
  static Map<String, dynamic> _noArgs() => const {};

  /// Whether a plugin uses hook [hookId].
  static bool has(String hookId) => PluginHooks.has(hookId);

  /// Whether a plugin uses the hook of built-in action [item] on [page].
  static bool hasAction(String page, String item) => PluginHooks.has(LibraryHooks.action(page, item));

  /// Runs built-in UI action [item] of [page] through hook `action.<page>.<item>`.
  ///
  /// [args] describes what the action works on (album, person, ...); it is built only when a plugin uses the hook.
  /// `before` may cancel (the returned future throws an error for which [isCancelled] is true) or change the
  /// arguments: with [withArgs] the action then runs from the changed arguments, without it they are informational.
  /// `instead` replaces the action, `after` sees `{args, result}`.
  static Future<T> action<T>(
    String page,
    String item,
    Future<T> Function() original, {
    Map<String, dynamic> Function() args = _noArgs,
    Future<T> Function(Map<String, dynamic> args)? withArgs,
    Object? Function(T value)? encode,
    T Function(Object? json)? decode,
  }) => PluginHooks.run<T>(
    LibraryHooks.action(page, item),
    () => {'page': page, 'item': item, ...args()},
    original,
    withArgs: withArgs,
    encode: encode,
    decode: decode,
  );

  /// Runs a named UI flow (`search.apply`, `private.unlock`, ...) through hook [hookId].
  static Future<T> flow<T>(
    String hookId,
    Future<T> Function() original, {
    Map<String, dynamic> Function() args = _noArgs,
    Future<T> Function(Map<String, dynamic> args)? withArgs,
    Object? Function(T value)? encode,
    T Function(Object? json)? decode,
    String? event,
  }) => PluginHooks.run<T>(hookId, args, original, withArgs: withArgs, encode: encode, decode: decode, event: event);

  /// Lets query hook [hookId] filter, sort or extend [items] (what a page is about to show).
  ///
  /// Plugins get `{args..., "items": [json]}` in `after` and answer with a list of items or ids: known ids map back
  /// to the original objects (a subset filters, another order sorts), unknown items are built with [fromJson] when
  /// given (extending the list) and dropped otherwise. Returns [items] itself, synchronously, while no plugin uses
  /// the hook. A plugin failure (or a `before` cancel, which queries do not support) shows [items] unchanged.
  static FutureOr<List<T>> query<T>(
    String hookId,
    List<T> items, {
    required String Function(T item) id,
    required Map<String, dynamic> Function(T item) toJson,
    T? Function(Map<String, dynamic> json)? fromJson,
    Map<String, dynamic> Function() args = _noArgs,
  }) {
    if (!PluginHooks.has(hookId)) {
      return items;
    }
    final codec = PluginListCodec<T>(id: id, toJson: toJson, fromJson: fromJson);
    try {
      final result = PluginHooks.filter<List<T>>(
        hookId,
        () => {...args(), 'count': items.length},
        items,
        encode: codec.encode,
        decode: codec.decode,
      );
      if (result is Future<List<T>>) {
        return result.catchError((Object _) => items);
      }
      return result;
    } catch (_) {
      return items;
    }
  }

  /// Emits [event] to subscribed plugins; [data] is built only when a plugin listens.
  static void emit(String event, Map<String, dynamic> Function() data) => PluginHooks.emit(event, data);

  /// Whether a plugin listens to [event].
  static bool listens(String event) => PluginHooks.listens(event);

  /// Whether [error] means a plugin cancelled the action.
  static bool isCancelled(Object error) => PluginHooks.isCancelled(error);

  /// The message a plugin gave when it cancelled.
  static String? cancelMessage(Object error) => PluginHooks.cancelMessage(error);

  /// The built-in items of a slot in the order to show them.
  ///
  /// Phase B applies the slot's built-in rules (hide, order, rename) and places plugin items among them; until a
  /// kernel is bound the built-in order is kept.
  static List<T> arrange<T>(String slot, List<LibrarySlotItem<T>> items) => [for (final entry in items) entry.item];
}
