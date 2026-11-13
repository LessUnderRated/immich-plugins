import 'dart:async';

import 'package:immich_mobile/domain/plugins/plugin_ids.dart';

/// Thrown by a cancellable hook when a plugin's `before` (or `instead`) phase returns `{ "cancel": true }`.
/// Call sites catch it and show [message] (if any) in a snackbar.
class PluginCancelled implements Exception {
  final String? message;
  final String hook;
  final String plugin;

  const PluginCancelled({this.message, required this.hook, required this.plugin});

  @override
  String toString() => message ?? 'Cancelled by $plugin ($hook)';
}

/// One plugin method registered for one phase of a hook (`contributes.hooks`).
///
/// (Named `PluginHookHandler` so it does not clash with the data layer's `PluginHookBinding` interface in
/// `lib/domain/utils/plugin_hooks.dart`, which the kernel implements.)
class PluginHookHandler {
  final String plugin;
  final String hook;
  final HookPhase phase;
  final String method;

  /// Higher runs first. Default 0. Equal priorities keep plugin load order.
  final int priority;

  /// Per hook timeout from the manifest (`timeoutMs`); null uses the kernel default (10 s).
  final Duration? timeout;

  /// Condition on the hook args (same matcher as slot `when`, see `matchesWhen`); the handler only runs for calls
  /// whose args match, so a hook can be scoped to one page or scope.
  final Object? when;

  const PluginHookHandler({
    required this.plugin,
    required this.hook,
    required this.phase,
    required this.method,
    this.priority = 0,
    this.timeout,
    this.when,
  });

  /// Whether this handler applies to a call with [args].
  bool appliesTo(Map<String, dynamic> args) => when == null || matchesWhen(when, args);

  Map<String, dynamic> toJson() => {
    'plugin': plugin,
    'hook': hook,
    'phase': phase.name,
    'method': method,
    'priority': priority,
    if (timeout != null) 'timeoutMs': timeout!.inMilliseconds,
    'when': ?when,
  };
}

/// Calls the plugin for one binding with the `HookV1` data and returns its response.
typedef PluginHookInvoker = Future<Map<String, dynamic>?> Function(PluginHookHandler binding, Map<String, dynamic> data);

/// Receives plugin failures and timeouts; the chain itself always falls back to the original behaviour.
typedef PluginHookErrorLogger = void Function(PluginHookHandler binding, Object error, StackTrace? stack);

/// The "patch" mechanism: runs an original operation wrapped by plugin hooks.
///
/// * `before` (by priority): `{ "cancel": true, "message"? }` throws [PluginCancelled];
///   `{ "args": {...} }` shallow-merges into the args seen by later hooks and the original.
/// * `instead`: the first plugin (by priority) returning `{ "result": x }` replaces the original;
///   `{ "fallthrough": true }`, `null` or no `result` continues with the next plugin, then the original.
/// * `after`: receives `{ "args", "result" }`; `{ "result": y }` replaces the result for later hooks and the caller.
///
/// A plugin that throws, times out or returns a result that cannot be decoded is logged and skipped. Only an explicit
/// `cancel` changes the outcome of the original call. Errors thrown by [original] itself propagate unchanged.
class PluginHookChain {
  static const defaultTimeout = Duration(seconds: 10);

  final String hook;
  final List<PluginHookHandler> bindings;
  final PluginHookInvoker invoke;
  final PluginHookErrorLogger? onError;
  final Duration timeout;

  /// Whether `{ "cancel": true }` is honoured. Hooks declared non-cancellable log and ignore it.
  final bool cancellable;

  PluginHookChain({
    required this.hook,
    required Iterable<PluginHookHandler> bindings,
    required this.invoke,
    this.onError,
    this.timeout = defaultTimeout,
    this.cancellable = true,
  }) : bindings = sortBindings(bindings);

  /// Sorts by priority (high first), keeping registration order for ties.
  static List<PluginHookHandler> sortBindings(Iterable<PluginHookHandler> bindings) {
    final indexed = bindings.toList().asMap().entries.toList()
      ..sort((a, b) {
        final byPriority = b.value.priority.compareTo(a.value.priority);
        return byPriority != 0 ? byPriority : a.key.compareTo(b.key);
      });
    return [for (final entry in indexed) entry.value];
  }

  Iterable<PluginHookHandler> _phase(HookPhase phase) => bindings.where((binding) => binding.phase == phase);

  Future<Map<String, dynamic>?> _call(PluginHookHandler binding, Map<String, dynamic> data) async {
    try {
      return await invoke(binding, data).timeout(binding.timeout ?? timeout);
    } catch (error, stack) {
      onError?.call(binding, error, stack);
      return null;
    }
  }

  Future<T> run<T>(
    Map<String, dynamic> args,
    FutureOr<T> Function(Map<String, dynamic> args) original, {
    Object? Function(T value)? encode,
    T Function(Object? json)? decode,
  }) async {
    var currentArgs = Map<String, dynamic>.of(args);

    for (final binding in _phase(HookPhase.before)) {
      final response = await _call(binding, {'hook': hook, 'phase': HookPhase.before.name, 'args': currentArgs});
      if (response == null) {
        continue;
      }
      _checkCancel(binding, response);
      final newArgs = response['args'];
      if (newArgs is Map) {
        currentArgs = {...currentArgs, ...Map<String, dynamic>.from(newArgs)};
      }
    }

    var hasResult = false;
    late T result;
    for (final binding in _phase(HookPhase.instead)) {
      final response = await _call(binding, {'hook': hook, 'phase': HookPhase.instead.name, 'args': currentArgs});
      if (response == null) {
        continue;
      }
      _checkCancel(binding, response);
      if (response['fallthrough'] == true || !response.containsKey('result')) {
        continue;
      }
      final decoded = _decode<T>(binding, response['result'], decode);
      if (decoded.$1) {
        result = decoded.$2 as T;
        hasResult = true;
        break;
      }
    }

    if (!hasResult) {
      result = await original(currentArgs);
    }

    final after = _phase(HookPhase.after).toList();
    if (after.isEmpty) {
      return result;
    }
    var encoded = _encode(result, encode);
    for (final binding in after) {
      final response = await _call(binding, {
        'hook': hook,
        'phase': HookPhase.after.name,
        'args': currentArgs,
        'result': encoded,
      });
      if (response == null || !response.containsKey('result')) {
        continue;
      }
      final decoded = _decode<T>(binding, response['result'], decode);
      if (decoded.$1) {
        result = decoded.$2 as T;
        encoded = response['result'];
      }
    }
    return result;
  }

  void _checkCancel(PluginHookHandler binding, Map<String, dynamic> response) {
    if (response['cancel'] == true) {
      if (!cancellable) {
        onError?.call(binding, StateError('Hook $hook cannot be cancelled; ignoring the cancel'), null);
        return;
      }
      final message = response['message'];
      throw PluginCancelled(
        message: message is String && message.isNotEmpty ? message : null,
        hook: hook,
        plugin: binding.plugin,
      );
    }
  }

  (bool, T?) _decode<T>(PluginHookHandler binding, Object? json, T Function(Object? json)? decode) {
    try {
      if (decode != null) {
        return (true, decode(json));
      }
      if (json is T) {
        return (true, json);
      }
      throw FormatException('Result of type ${json.runtimeType} does not fit the hook result');
    } catch (error, stack) {
      onError?.call(binding, error, stack);
      return (false, null);
    }
  }

  static Object? _encode<T>(T value, Object? Function(T value)? encode) {
    if (encode != null) {
      return encode(value);
    }
    return isJsonValue(value) ? value : null;
  }

  /// Whether [value] can be sent to a plugin as JSON unchanged.
  static bool isJsonValue(Object? value) {
    if (value == null || value is String || value is num || value is bool) {
      return true;
    }
    if (value is List) {
      return value.every(isJsonValue);
    }
    if (value is Map) {
      return value.keys.every((key) => key is String) && value.values.every(isJsonValue);
    }
    return false;
  }
}

/// Rate limits a stream of values per key: the first value is delivered at once, later ones at most once per
/// [interval] (the latest value wins, delivered at the end of the interval).
class PluginThrottle<T> {
  final Duration interval;
  final void Function(String key, T value) deliver;
  final Map<String, DateTime> _last = {};
  final Map<String, T> _pending = {};
  final Map<String, Timer> _timers = {};

  PluginThrottle({required this.interval, required this.deliver});

  void add(String key, T value) {
    final now = DateTime.now();
    final last = _last[key];
    if (last == null || now.difference(last) >= interval) {
      _last[key] = now;
      deliver(key, value);
      return;
    }
    _pending[key] = value;
    _timers[key] ??= Timer(interval - now.difference(last), () {
      _timers.remove(key);
      if (_pending.containsKey(key)) {
        _last[key] = DateTime.now();
        deliver(key, _pending.remove(key) as T);
      }
    });
  }

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _pending.clear();
  }
}
