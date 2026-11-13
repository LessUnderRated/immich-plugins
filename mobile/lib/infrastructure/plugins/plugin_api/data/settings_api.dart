import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/utils/plugin_settings.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';

/// Every app setting and Store key: `settings.get`, `settings.set`, `settings.reset`, `settings.list`.
///
/// Keys are `app.<name>` (app settings such as `app.themeMode`, `app.timelineTilesPerRow`) and `store.<name>` (the
/// key-value store such as `store.viewerCensor`). Writes run the `settings.set` hook and emit `settings.changed`, and
/// the UI follows them at once (both stores are watched by the app).
class SettingsHostApi implements DataHostModule {
  final StoreService _store;
  final SettingsRepository _settings;

  const SettingsHostApi(this._store, this._settings);

  @override
  Map<String, DataHostFunction> get functions => {
    'settings.get': (plugin, args) async => get(HostArgs(args).text(0, 'key')),
    'settings.set': (plugin, args) => set(HostArgs(args).text(0, 'key'), HostArgs(args)[1]),
    'settings.reset': (plugin, args) => reset(HostArgs(args).text(0, 'key')),
    'settings.list': (plugin, args) async => list(prefix: HostArgs(args).map(0).text('prefix')),
  };

  @override
  Map<String, String> get docs => const {
    'settings.get': '[key] -> value (JSON: enums by name, dates ISO, lists, maps)',
    'settings.set': '[key, value] -> { key, value } (null resets to the default)',
    'settings.reset': '[key] -> { key, value } (the default)',
    'settings.list': '[{ prefix? }] -> [{ key, type, value, default, values?, writable, sensitive? }]',
  };

  Object? get(String key) {
    final app = PluginSettings.parseAppKey(key);
    if (app != null) {
      return PluginSettings.encodeApp(_settings.appConfig.read(app));
    }
    final store = PluginSettings.parseStoreKey(key);
    if (store != null) {
      return PluginSettings.encodeStore(_store.values[store]);
    }
    throw DataHostException.notFound('Unknown setting $key');
  }

  Future<Map<String, dynamic>> set(String key, Object? value) async {
    try {
      final app = PluginSettings.parseAppKey(key);
      if (app != null) {
        final decoded = PluginSettings.decodeApp(app, value);
        await (decoded == null ? _settings.clear([app]) : _writeApp(app, decoded));
        return {'key': key, 'value': get(key)};
      }
      final store = PluginSettings.parseStoreKey(key);
      if (store != null) {
        if (PluginSettings.readOnlyStoreKeys.contains(store)) {
          throw DataHostException(403, '$key is managed by the app');
        }
        final decoded = PluginSettings.decodeStore(store, value);
        await (decoded == null ? _store.delete(store) : _writeStore(store, decoded));
        return {'key': key, 'value': get(key)};
      }
    } on PluginSettingException catch (error) {
      throw DataHostException.badRequest(error.message);
    }
    throw DataHostException.notFound('Unknown setting $key');
  }

  Future<void> _writeApp<T>(SettingsKey<T> key, Object value) => _settings.write<T, T>(key, value as T);

  Future<void> _writeStore<T>(StoreKey<T> key, Object value) => _store.put<StoreKey<T>, T>(key, value as T);

  Future<Map<String, dynamic>> reset(String key) => set(key, null);

  List<Map<String, dynamic>> list({String? prefix}) {
    final config = _settings.appConfig;
    final storeValues = _store.values;
    final entries = [
      for (final key in SettingsKey.values)
        {
          'key': PluginSettings.appKey(key),
          'type': PluginSettings.appType(key),
          'value': PluginSettings.encodeApp(config.read(key)),
          'default': PluginSettings.encodeApp(defaultConfig.read(key)),
          'values': ?PluginSettings.appEnumValues(key),
          'writable': true,
        },
      for (final key in StoreKey.values)
        if (!key.name.startsWith('legacy'))
          {
            'key': PluginSettings.storeKey(key),
            'type': PluginSettings.storeType(key),
            'value': PluginSettings.encodeStore(storeValues[key]),
            'default': null,
            'writable': !PluginSettings.readOnlyStoreKeys.contains(key) && PluginSettings.storeType(key) != 'user',
            if (PluginSettings.sensitiveStoreKeys.contains(key)) 'sensitive': true,
          },
    ];
    return prefix == null ? entries : entries.where((entry) => '${entry['key']}'.startsWith(prefix)).toList();
  }
}
