import 'dart:async';

/// Arguments of a hook call, exactly as plugins see them (JSON-compatible values only).
typedef PluginHookArgs = Map<String, dynamic>;

/// What the plugin kernel provides to the data layer.
///
/// The data layer (services, repositories, the HTTP client) only knows this interface, so it stays free of
/// infrastructure imports and works unchanged where no kernel exists (background isolates, tests). The kernel binds
/// an implementation at startup with [PluginHooks.bind]; it mirrors `PluginKernel.hasHook`, `run` and `emit`.
abstract interface class PluginHookBinding {
  /// Whether any enabled plugin registered a `before`, `instead` or `after` handler for [hookId].
  bool hasHook(String hookId);

  /// Whether any enabled plugin subscribed to [event] (exactly, by prefix pattern or `*`).
  bool hasListeners(String event);

  /// Runs [original] wrapped by every plugin handler registered for [hookId] (see `PluginKernel.run`).
  /// A `before` handler that cancels makes this throw an error for which [isCancellation] is true.
  Future<T> run<T>(
    String hookId,
    PluginHookArgs args,
    Future<T> Function(PluginHookArgs args) original, {
    Object? Function(T value)? encode,
    T Function(Object? json)? decode,
  });

  /// Delivers [event] to subscribed plugins without blocking the caller.
  void emit(String event, Map<String, dynamic> data);

  /// Whether [error] is the kernel's "a plugin cancelled this hook" error (`PluginCancelled`).
  bool isCancellation(Object error);

  /// The user-facing message of a cancellation error, if the plugin gave one.
  String? cancellationMessage(Object error);
}

/// Hook points and events of the data layer.
///
/// Every call is free when no kernel is bound or no plugin uses the hook: [run] then returns `original()` itself,
/// [filter] returns the value unchanged and [emit] builds nothing.
abstract final class PluginHooks {
  static PluginHookBinding? _binding;

  /// Installs (or with `null` removes) the kernel binding.
  static void bind(PluginHookBinding? binding) => _binding = binding;

  static bool get isBound => _binding != null;

  /// Whether a plugin handles [hookId]. Use it before building expensive hook arguments.
  static bool has(String hookId) => _binding?.hasHook(hookId) ?? false;

  /// Whether a plugin listens to [event].
  static bool listens(String event) => _binding?.hasListeners(event) ?? false;

  /// Whether [error] means a plugin cancelled the operation (a `before` handler returned `{"cancel": true}`).
  static bool isCancelled(Object error) => _binding?.isCancellation(error) ?? false;

  /// The message a plugin attached when it cancelled the operation.
  static String? cancelMessage(Object error) => _binding?.cancellationMessage(error);

  /// Runs the mutation or query [original] through hook [hookId].
  ///
  /// [args] builds the JSON plugins see; it is only called when a plugin uses the hook or listens to [event].
  /// When given, [withArgs] runs the operation from the (possibly plugin-modified) arguments; without it the
  /// arguments are informational and [original] runs as called. [encode] turns the result into JSON for `after`
  /// handlers; [decode] turns a replacement result back (without it, results cannot be replaced).
  /// [event] is emitted after the built-in operation succeeded, with [eventData] (default: the arguments).
  static Future<T> run<T>(
    String hookId,
    PluginHookArgs Function() args,
    Future<T> Function() original, {
    Future<T> Function(PluginHookArgs args)? withArgs,
    Object? Function(T value)? encode,
    T Function(Object? json)? decode,
    String? event,
    Map<String, dynamic> Function(PluginHookArgs args, T result)? eventData,
  }) {
    final binding = _binding;
    if (binding == null) {
      return original();
    }
    final hooked = binding.hasHook(hookId);
    final emits = event != null && binding.hasListeners(event);
    if (!hooked && !emits) {
      return original();
    }

    final built = args();
    Future<T> runOriginal(PluginHookArgs current) async {
      final changed = withArgs != null && !_sameArgs(built, current);
      final result = await (changed ? withArgs(current) : original());
      if (emits) {
        _emitSafely(binding, event, () => eventData?.call(current, result) ?? current);
      }
      return result;
    }

    if (!hooked) {
      return runOriginal(built);
    }
    return binding.run<T>(hookId, built, runOriginal, encode: encode, decode: decode);
  }

  /// Lets `after` handlers of query hook [hookId] change [value] (filter, sort, extend). Returns [value] itself,
  /// synchronously, when no plugin uses the hook.
  static FutureOr<T> filter<T>(
    String hookId,
    PluginHookArgs Function() args,
    T value, {
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
  }) {
    final binding = _binding;
    if (binding == null || !binding.hasHook(hookId)) {
      return value;
    }
    return binding.run<T>(hookId, args(), (_) async => value, encode: encode, decode: decode);
  }

  /// Applies query hook [hookId] to every value of [source]. Values pass through untouched (and synchronously)
  /// while no plugin uses the hook.
  static Stream<T> filterStream<T>(
    Stream<T> source,
    String hookId,
    PluginHookArgs Function() args, {
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
  }) => source.asyncMap((value) => filter<T>(hookId, args, value, encode: encode, decode: decode));

  /// Emits [event]; [data] is only built when a plugin listens.
  static void emit(String event, Map<String, dynamic> Function() data) {
    final binding = _binding;
    if (binding == null || !binding.hasListeners(event)) {
      return;
    }
    _emitSafely(binding, event, data);
  }

  static void _emitSafely(PluginHookBinding binding, String event, Map<String, dynamic> Function() data) {
    try {
      binding.emit(event, data());
    } catch (_) {
      // Events never break the operation that emitted them.
    }
  }

  static bool _sameArgs(PluginHookArgs a, PluginHookArgs b) {
    if (identical(a, b)) {
      return true;
    }
    if (a.length != b.length) {
      return false;
    }
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || !_sameValue(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }

  static bool _sameValue(Object? a, Object? b) {
    if (identical(a, b) || a == b) {
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) {
        return false;
      }
      for (var i = 0; i < a.length; i++) {
        if (!_sameValue(a[i], b[i])) {
          return false;
        }
      }
      return true;
    }
    if (a is Map && b is Map) {
      return _sameArgs(Map<String, dynamic>.from(a), Map<String, dynamic>.from(b));
    }
    return false;
  }
}

/// Encodes a list result for `after` hooks and maps the plugin's answer back.
///
/// A plugin answers with a list of items (or ids). Items whose `id` matches an item of the original result map back
/// to that original object, so returning a subset filters and returning another order sorts. Items with an unknown
/// id are built with [fromJson] when given (extending the result) and dropped otherwise.
class PluginListCodec<T> {
  final String Function(T item) id;
  final Map<String, dynamic> Function(T item) toJson;
  final T? Function(Map<String, dynamic> json)? fromJson;
  Map<String, T> _byId = const {};

  PluginListCodec({required this.id, required this.toJson, this.fromJson});

  Object? encode(List<T> items) {
    _byId = {for (final item in items) id(item): item};
    return [for (final item in items) toJson(item)];
  }

  List<T> decode(Object? json) {
    if (json is! List) {
      return _byId.values.toList();
    }
    final result = <T>[];
    for (final entry in json) {
      if (entry is String || entry is num) {
        final item = _byId['$entry'];
        if (item != null) {
          result.add(item);
        }
        continue;
      }
      if (entry is! Map) {
        continue;
      }
      final map = Map<String, dynamic>.from(entry);
      final known = _byId['${map['id']}'];
      if (known != null) {
        result.add(known);
        continue;
      }
      final built = fromJson?.call(map);
      if (built != null) {
        result.add(built);
      }
    }
    return result;
  }
}

/// JSON helpers for hook arguments built from plugin input.
abstract final class PluginArgs {
  static List<String> strings(Object? value) =>
      value is List ? [for (final item in value) if (item != null) '$item'] : const [];

  static String? string(Object? value) => value == null ? null : '$value';

  static bool? boolean(Object? value) => switch (value) {
    final bool b => b,
    final num n => n != 0,
    'true' => true,
    'false' => false,
    _ => null,
  };

  static int? integer(Object? value) => switch (value) {
    final num n => n.toInt(),
    final String s => int.tryParse(s),
    _ => null,
  };

  static double? real(Object? value) => switch (value) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s),
    _ => null,
  };

  static DateTime? date(Object? value) => switch (value) {
    final String s => DateTime.tryParse(s),
    final num n => DateTime.fromMillisecondsSinceEpoch(n.toInt()),
    _ => null,
  };

  static String? iso(DateTime? value) => value?.toUtc().toIso8601String();
}
