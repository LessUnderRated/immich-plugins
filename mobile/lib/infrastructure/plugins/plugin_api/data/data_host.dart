import 'package:immich_mobile/domain/utils/plugin_hooks.dart';

/// A host function as the data area implements it: the calling plugin's name and the JSON argument array.
/// The kernel registers each one with `registerHost(name, ...)`.
typedef DataHostFunction = Future<Object?> Function(String plugin, List<dynamic> args);

/// A failed host call with an HTTP-like status (400 bad arguments, 404 not found, 409 conflict, 501 not available
/// on this device or server). The kernel turns it into `{ "success": false, "status", "message" }`.
class DataHostException implements Exception {
  final int status;
  final String message;

  const DataHostException(this.status, this.message);

  const DataHostException.badRequest(this.message) : status = 400;

  const DataHostException.notFound(this.message) : status = 404;

  const DataHostException.unsupported(this.message) : status = 501;

  @override
  String toString() => message;
}

/// A group of host functions of one namespace (`db.*`, `assets.*`, ...).
abstract class DataHostModule {
  /// Function name to implementation.
  Map<String, DataHostFunction> get functions;

  /// Function name to a one-line `args -> result` description, for `kernel.hosts` introspection.
  Map<String, String> get docs;
}

/// Typed access to a host call's argument array.
extension type const HostArgs(List<dynamic> args) {
  Object? operator [](int index) => index < args.length ? args[index] : null;

  bool has(int index) => index < args.length && args[index] != null;

  /// The argument at [index] as an object; `{}` when missing.
  Map<String, dynamic> map(int index) {
    final value = this[index];
    return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  }

  /// A required string argument.
  String text(int index, String name) {
    final value = this[index];
    if (value == null || (value is String && value.isEmpty)) {
      throw DataHostException.badRequest('Missing argument $name');
    }
    return '$value';
  }

  String? optText(int index) => PluginArgs.string(this[index]);

  /// A list of ids given either as a list or as a single id.
  List<String> ids(int index, String name) {
    final value = this[index];
    final ids = value is List ? PluginArgs.strings(value) : [if (value != null) '$value'];
    if (ids.isEmpty) {
      throw DataHostException.badRequest('Missing argument $name');
    }
    return ids;
  }

  bool boolean(int index, String name) {
    final value = PluginArgs.boolean(this[index]);
    if (value == null) {
      throw DataHostException.badRequest('Missing argument $name (true or false)');
    }
    return value;
  }
}

/// Reads typed options from an options object.
extension HostOptions on Map<String, dynamic> {
  String? text(String key) => PluginArgs.string(this[key]);

  int? integer(String key) => PluginArgs.integer(this[key]);

  double? real(String key) => PluginArgs.real(this[key]);

  bool? flag(String key) => PluginArgs.boolean(this[key]);

  DateTime? date(String key) => PluginArgs.date(this[key]);

  List<String> strings(String key) => PluginArgs.strings(this[key]);

  Map<String, dynamic> object(String key) {
    final value = this[key];
    return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  }

  Map<String, String> stringMap(String key) {
    final value = this[key];
    return value is Map ? {for (final entry in value.entries) '${entry.key}': '${entry.value}'} : <String, String>{};
  }
}

/// The result shape of bulk asset operations: which ids changed, which ids the operation does not support (e.g. a
/// server-only change on a device asset) and which ids are unknown.
class BulkResult {
  final List<String> done = [];
  final List<String> unsupported = [];
  final List<String> unknown = [];
  final List<Map<String, dynamic>> errors = [];

  Map<String, dynamic> toJson() => {
    'count': done.length,
    'ids': done,
    if (unsupported.isNotEmpty) 'unsupported': unsupported,
    if (unknown.isNotEmpty) 'unknown': unknown,
    if (errors.isNotEmpty) 'errors': errors,
  };
}
