import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_ui/immich_ui.dart' show scaffoldMessengerKey;

/// Hook call helpers for the shell's UI operations (login, share and view intents, logs, locale, backup).
///
/// Built on [PluginHooks], which the kernel binds at startup: with no kernel or no plugin on the hook the operation
/// runs directly with no extra work.
abstract final class ShellHookRunner {
  /// Runs [operation] through hook [hookId] with [args].
  ///
  /// A `before` handler may change the arguments (the operation then gets the changed ones) or cancel: a cancelled
  /// operation shows the plugin's message (if any) in a snackbar and returns null. `instead` handlers replace the
  /// operation when [decode] is given (or for `void`-like results where [decode] returns a placeholder). [event] is
  /// emitted after the operation succeeded.
  static Future<T?> guard<T>(
    String hookId,
    Map<String, dynamic> args,
    Future<T> Function(Map<String, dynamic> args) operation, {
    Object? Function(T value)? encode,
    T Function(Object? json)? decode,
    String? event,
    Map<String, dynamic> Function(Map<String, dynamic> args, T result)? eventData,
  }) async {
    try {
      return await PluginHooks.run<T>(
        hookId,
        () => args,
        () => operation(args),
        withArgs: operation,
        encode: encode,
        decode: decode,
        event: event,
        eventData: eventData,
      );
    } catch (error) {
      if (!PluginHooks.isCancelled(error)) {
        rethrow;
      }
      showCancelled(error);
      return null;
    }
  }

  /// Whether a plugin handles [hookId] (to skip building expensive arguments).
  static bool has(String hookId) => PluginHooks.has(hookId);

  /// Emits [event]; [data] is only built when a plugin listens.
  static void emit(String event, Map<String, dynamic> Function() data) => PluginHooks.emit(event, data);

  /// Shows the message a plugin attached to a cancellation, if any.
  static void showCancelled(Object error) {
    final message = PluginHooks.cancelMessage(error);
    if (message != null && message.isNotEmpty) {
      scaffoldMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
