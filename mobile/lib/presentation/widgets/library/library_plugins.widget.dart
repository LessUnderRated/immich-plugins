import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/providers/timeline/timeline_plugins.provider.dart';

/// Runs built-in action [item] of library page [page] through its plugin hook (`action.<page>.<item>`).
///
/// When a plugin cancels, its message (if any) is shown in a snackbar and null is returned. Errors of the action
/// itself propagate unchanged. Without plugins this is `original()`.
Future<T?> runLibraryAction<T>(
  BuildContext context,
  String page,
  String item,
  Future<T> Function() original, {
  Map<String, dynamic> Function()? args,
  Future<T> Function(Map<String, dynamic> args)? withArgs,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    return await LibraryPluginHooks.action<T>(page, item, original, args: args ?? () => const {}, withArgs: withArgs);
  } catch (error) {
    if (!LibraryPluginHooks.isCancelled(error)) {
      rethrow;
    }
    showLibraryCancelMessage(messenger, error);
    return null;
  }
}

/// [runLibraryAction] for tap callbacks: starts the action and returns immediately.
void libraryTap(
  BuildContext context,
  String page,
  String item,
  FutureOr<void> Function() original, {
  Map<String, dynamic> Function()? args,
}) => unawaited(runLibraryAction<void>(context, page, item, () async => original(), args: args));

/// Runs UI flow [hookId] (`search.apply`, `private.unlock`, ...) like [runLibraryAction].
Future<T?> runLibraryFlow<T>(
  BuildContext context,
  String hookId,
  Future<T> Function() original, {
  Map<String, dynamic> Function()? args,
  Future<T> Function(Map<String, dynamic> args)? withArgs,
  String? event,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    return await LibraryPluginHooks.flow<T>(
      hookId,
      original,
      args: args ?? () => const {},
      withArgs: withArgs,
      event: event,
    );
  } catch (error) {
    if (!LibraryPluginHooks.isCancelled(error)) {
      rethrow;
    }
    showLibraryCancelMessage(messenger, error);
    return null;
  }
}

/// Shows the message a plugin gave when it cancelled an action.
void showLibraryCancelMessage(ScaffoldMessengerState? messenger, Object error) {
  final message = LibraryPluginHooks.cancelMessage(error);
  if (message != null && message.isNotEmpty) {
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Builds a list a library page shows after query hook [hook] had its say (`LibraryPluginHooks.query`).
///
/// Without a plugin on the hook, [builder] gets [items] directly in the same frame. With one, the result is computed
/// once per distinct input ([items] by element identity and [argsKey]) and [placeholder] (default: nothing) shows
/// until the first result is ready, so items a plugin hides never flash.
class LibraryQueryBuilder<T> extends StatefulWidget {
  final String hook;
  final List<T> items;
  final String Function(T item) id;
  final Map<String, dynamic> Function(T item) toJson;
  final T? Function(Map<String, dynamic> json)? fromJson;
  final Map<String, dynamic> Function()? args;

  /// Anything besides [items] the result depends on (a search text, a sort order).
  final Object? argsKey;
  final Widget Function(BuildContext context, List<T> items) builder;
  final WidgetBuilder? placeholder;

  const LibraryQueryBuilder({
    super.key,
    required this.hook,
    required this.items,
    required this.id,
    required this.toJson,
    required this.builder,
    this.fromJson,
    this.args,
    this.argsKey,
    this.placeholder,
  });

  @override
  State<LibraryQueryBuilder<T>> createState() => _LibraryQueryBuilderState<T>();
}

class _LibraryQueryBuilderState<T> extends State<LibraryQueryBuilder<T>> {
  List<T>? _input;
  Object? _inputKey;
  Future<List<T>>? _pending;
  List<T>? _result;

  bool _sameInput(List<T> items, Object? key) {
    final input = _input;
    if (input == null || key != _inputKey || input.length != items.length) {
      return false;
    }
    for (var i = 0; i < items.length; i++) {
      if (!identical(input[i], items[i])) {
        return false;
      }
    }
    return true;
  }

  void _run() {
    final items = widget.items;
    if (_sameInput(items, widget.argsKey)) {
      return;
    }
    _input = items;
    _inputKey = widget.argsKey;
    final result = LibraryPluginHooks.query<T>(
      widget.hook,
      items,
      id: widget.id,
      toJson: widget.toJson,
      fromJson: widget.fromJson,
      args: widget.args ?? () => const {},
    );
    if (result is Future<List<T>>) {
      final pending = result;
      _pending = pending;
      unawaited(
        pending.then((value) {
          if (mounted && identical(_pending, pending)) {
            setState(() {
              _result = value;
              _pending = null;
            });
          }
        }),
      );
    } else {
      _pending = null;
      _result = result;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!LibraryPluginHooks.has(widget.hook)) {
      _input = null;
      _result = null;
      _pending = null;
      return widget.builder(context, widget.items);
    }
    _run();
    final result = _result;
    if (result == null) {
      return widget.placeholder?.call(context) ?? const SizedBox.shrink();
    }
    return widget.builder(context, result);
  }
}

/// A library tile (album, person, place, partner, ...) decorated by the plugins of its tile [slot]: badges, wraps or
/// a full replacement. [slotContext] describes the tile (e.g. `{"album": {...}}`). Free when no plugin decorates it.
class LibraryTileDecoration extends ConsumerWidget {
  final String slot;
  final Map<String, dynamic> Function() slotContext;
  final Widget child;

  /// The slot of the tile's long-press menu (default `<slot>.menu`); plugin entries open on long press.
  final String? menuSlot;

  const LibraryTileDecoration({
    super.key,
    required this.slot,
    required this.slotContext,
    required this.child,
    this.menuSlot,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bridge = ref.watch(timelinePluginBridgeProvider);
    final menu = menuSlot ?? '$slot.menu';
    final hasDecorations = bridge.hasDecorations(slot);
    final entries = bridge.menuItems(menu, const {});
    if (!hasDecorations && entries.isEmpty) {
      return child;
    }
    final context0 = slotContext();
    final decorated = hasDecorations ? bridge.decorate(slot, context0, child) : child;
    if (entries.isEmpty) {
      return decorated;
    }
    final items = bridge.menuItems(menu, context0);
    return MenuAnchor(
      consumeOutsideTap: true,
      menuChildren: [for (final item in items) item.item],
      builder: (context, controller, child) => GestureDetector(
        onLongPressStart: (details) => controller.open(position: details.localPosition),
        child: child,
      ),
      child: decorated,
    );
  }
}
