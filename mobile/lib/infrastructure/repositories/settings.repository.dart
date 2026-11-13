import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/app/settings.drift.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_settings.dart';
import 'package:immich_mobile/infrastructure/repositories/cached_key_value_repository.dart';

class SettingsRepository extends CachedKeyValueRepository<SettingsKey, AppConfig> {
  final Drift _db;

  SettingsRepository._(this._db) : super(const .new());

  static SettingsRepository? _instance;

  static SettingsRepository get instance {
    final instance = _instance;
    if (instance == null) {
      throw StateError('SettingsRepository not initialized. Call ensureInitialized() first');
    }
    return instance;
  }

  static Future<SettingsRepository> ensureInitialized(Drift db) async {
    if (_instance == null) {
      final instance = SettingsRepository._(db);
      await instance.refresh();
      _instance = instance;
    }
    return _instance!;
  }

  @visibleForTesting
  static Future<void> reset() async {
    final instance = _instance;
    if (instance != null) {
      await instance.clear(SettingsKey.values);
      _instance = null;
    }
  }

  @override
  List<SettingsKey> get keys => SettingsKey.values;

  @override
  Object decodeValue(SettingsKey key, String raw) => key.decode(raw);

  @override
  AppConfig buildSnapshot(Map<SettingsKey, Object?> overrides) => AppConfig.fromEntries(overrides);

  @override
  Selectable<({String key, String? value})> selectable() =>
      _db.select(_db.settingsEntity).map((row) => (key: row.key, value: row.value));

  AppConfig get appConfig => snapshot;

  /// Resets [keys] to their defaults; runs as `settings.set` with `reset: true` and emits `settings.changed`.
  Future<void> clear(Iterable<SettingsKey> keys) {
    final list = keys.toList();
    if (list.isEmpty) {
      return Future.value();
    }
    return PluginHooks.run<void>(
      DataHooks.settingsSet,
      () => {
        'key': PluginSettings.appKey(list.first),
        'keys': [for (final key in list) PluginSettings.appKey(key)],
        'store': 'app',
        'value': null,
        'previous': PluginSettings.encodeApp(snapshot.read(list.first)),
        'reset': true,
      },
      () => _clear(list),
      event: DataEvents.settingsChanged,
    );
  }

  Future<void> _clear(Iterable<SettingsKey> keys) async {
    if (keys.isEmpty) {
      return;
    }

    final names = keys.map((key) => key.name).toList();
    await (_db.delete(_db.settingsEntity)..where((row) => row.key.isIn(names))).go();

    var config = snapshot;
    for (final key in keys) {
      config = config.write(key, defaultConfig.read(key));
    }
    snapshot = config;
  }

  /// Writes an app setting; runs as `settings.set` (`store: "app"`) and emits `settings.changed`.
  Future<void> write<T, U extends T>(SettingsKey<T> key, U value) async {
    if (value == snapshot.read(key)) {
      return;
    }
    final previous = snapshot.read(key);
    await PluginHooks.run<void>(
      DataHooks.settingsSet,
      () => {
        'key': PluginSettings.appKey(key),
        'store': 'app',
        'value': PluginSettings.encodeApp(value),
        'previous': PluginSettings.encodeApp(previous),
      },
      () => _write<T, U>(key, value),
      withArgs: (args) {
        final changed = PluginSettings.decodeApp(key, args['value']);
        return changed == null ? _clear([key]) : _write<T, T>(key, changed as T);
      },
      event: DataEvents.settingsChanged,
    );
  }

  Future<void> _write<T, U extends T>(SettingsKey<T> key, U value) async {
    if (value == snapshot.read(key)) {
      return;
    }

    if (value == defaultConfig.read(key)) {
      return _clear([key]);
    }

    String? resolvedValue;
    if (value != null) {
      resolvedValue = key.encode(value);
    }

    await _db
        .into(_db.settingsEntity)
        .insertOnConflictUpdate(
          SettingsEntityCompanion.insert(key: key.name, value: .new(resolvedValue), updatedAt: .new(DateTime.now())),
        );
    snapshot = snapshot.write(key, value);
  }

  Stream<AppConfig> watchConfig() => watchSnapshot();
}
