import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/plugins/plugin_ids.dart';

/// How one toggle is stored. App (built-in) code can back a toggle by its own setting with [read] / [write];
/// everything else is persisted by the kernel (`kernel.json` in the plugins folder).
class PluginToggleDefinition {
  /// `<owner>/<id>`: a plugin name or `app`, then the toggle id.
  final String key;
  final bool defaultValue;

  /// Reads the current value from external storage (a built-in setting). Called on every [PluginToggles.get].
  final bool Function()? read;

  /// Writes the value to external storage. Without it the kernel persists the value.
  final Future<void> Function(bool value)? write;

  /// Shown in `toggles.list` and on the Plugins page.
  final String? title;

  const PluginToggleDefinition({required this.key, this.defaultValue = false, this.read, this.write, this.title});
}

/// On/off state per plugin and id (slot kind `toggle`, host functions `toggles.*`, event `toggle.changed`).
///
/// Keys are `<owner>/<id>`; owners are plugin names or `app` for built-in toggles (the viewer censor shield is
/// `app/viewer.shield` once the viewer area moves it here). Every change notifies listeners and emits
/// `toggle.changed` with `{ "key", "owner", "id", "value", "source" }`.
class PluginToggles extends ChangeNotifier {
  final Map<String, bool> _values = {};
  final Map<String, PluginToggleDefinition> _definitions = {};

  /// Persists the stored values; set by the kernel.
  Future<void> Function(Map<String, bool> values)? persist;

  /// Emits `toggle.changed`; set by the kernel.
  void Function(String event, Map<String, dynamic> data)? emit;

  /// Loads persisted values (called once by the kernel).
  void restore(Map<String, bool> values) {
    _values
      ..clear()
      ..addAll(values);
    notifyListeners();
  }

  /// Declares a toggle (its default, and optionally external storage). Re-defining replaces the definition.
  void define(PluginToggleDefinition definition) {
    _definitions[definition.key] = definition;
  }

  /// Declares the toggles of plugin `toggle` slot items; definitions of other owners are kept.
  void definePluginDefaults(Map<String, bool> defaults) {
    _definitions.removeWhere((key, definition) => definition.read == null && !key.startsWith('$appToggleOwner/'));
    for (final MapEntry(:key, :value) in defaults.entries) {
      _definitions.putIfAbsent(key, () => PluginToggleDefinition(key: key, defaultValue: value));
    }
  }

  PluginToggleDefinition? definition(String key) => _definitions[key];

  /// The current value of [key]; [defaultValue] (or the definition's default) when it was never set.
  bool get(String key, {bool? defaultValue}) {
    final definition = _definitions[key];
    final read = definition?.read;
    if (read != null) {
      try {
        return read();
      } catch (_) {
        return definition?.defaultValue ?? defaultValue ?? false;
      }
    }
    return _values[key] ?? defaultValue ?? definition?.defaultValue ?? false;
  }

  /// Convenience for app code: `getFor('app', 'viewer.shield')`.
  bool getFor(String owner, String id, {bool? defaultValue}) => get(toggleKey(owner, id), defaultValue: defaultValue);

  /// Sets [key] to [value]; [source] is the plugin (or `app`) that changed it.
  Future<void> set(String key, bool value, {String source = appToggleOwner}) async {
    final previous = get(key);
    final definition = _definitions[key];
    final write = definition?.write;
    if (write != null) {
      await write(value);
    } else {
      _values[key] = value;
      unawaited(persist?.call(Map.of(_values)));
    }
    if (previous != value) {
      notifyListeners();
      final (owner, id) = parseToggleKey(key, defaultOwner: appToggleOwner);
      emit?.call('toggle.changed', {'key': key, 'owner': owner, 'id': id, 'value': value, 'source': source});
    }
  }

  /// Flips [key] and returns the new value.
  Future<bool> toggle(String key, {String source = appToggleOwner}) async {
    final value = !get(key);
    await set(key, value, source: source);
    return value;
  }

  /// Every known toggle (defined or stored) with its value.
  Map<String, bool> get all => {
    for (final key in {..._definitions.keys, ..._values.keys}) key: get(key),
  };

  List<Map<String, dynamic>> describe() => [
    for (final MapEntry(:key, :value) in all.entries)
      {
        'key': key,
        'owner': parseToggleKey(key, defaultOwner: appToggleOwner).$1,
        'id': parseToggleKey(key, defaultOwner: appToggleOwner).$2,
        'value': value,
        if (_definitions[key]?.title != null) 'title': _definitions[key]!.title,
      },
  ];
}
