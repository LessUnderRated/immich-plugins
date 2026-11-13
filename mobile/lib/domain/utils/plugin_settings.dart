import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:immich_mobile/constants/colors.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/log.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/providers/album/album_sort_by_options.provider.dart';
import 'package:immich_mobile/utils/semver.dart';

/// Thrown when a plugin value cannot be stored in a setting.
class PluginSettingException implements Exception {
  final String message;

  const PluginSettingException(this.message);

  @override
  String toString() => message;
}

/// Names, types and JSON codecs of every setting plugins can read and write.
///
/// * `app.<name>`: the app settings (`SettingsKey`, the `settings` table), e.g. `app.themeMode`.
/// * `store.<name>`: the key-value store (`StoreKey`, the `store` table), e.g. `store.viewerCensor`.
abstract final class PluginSettings {
  static const appPrefix = 'app.';
  static const storePrefix = 'store.';

  /// Store keys whose values are secrets of the server login: readable (plugins run without a sandbox) but marked.
  static const sensitiveStoreKeys = {StoreKey.accessToken};

  /// Store keys plugins cannot write (managed by the app).
  static const readOnlyStoreKeys = {StoreKey.version, StoreKey.currentUser, StoreKey.syncMigrationStatus};

  static String appKey(SettingsKey key) => '$appPrefix${key.name}';

  static String storeKey(StoreKey key) => '$storePrefix${key.name}';

  static SettingsKey? parseAppKey(String name) => name.startsWith(appPrefix)
      ? SettingsKey.values.where((key) => key.name == name.substring(appPrefix.length)).firstOrNull
      : null;

  static StoreKey? parseStoreKey(String name) => name.startsWith(storePrefix)
      ? StoreKey.values.where((key) => key.name == name.substring(storePrefix.length)).firstOrNull
      : null;

  static final Map<Type, List<Enum>> _enums = {
    ImmichColorPreset: ImmichColorPreset.values,
    ThemeMode: ThemeMode.values,
    AlbumSortMode: AlbumSortMode.values,
    GroupAssetsBy: GroupAssetsBy.values,
    LogLevel: LogLevel.values,
    AssetKeepType: AssetKeepType.values,
    ShareAssetType: ShareAssetType.values,
    SlideshowLook: SlideshowLook.values,
    SlideshowDirection: SlideshowDirection.values,
  };

  /// Types of settings whose default is null, so the type cannot be read from the default.
  static const _nullableTypes = {
    SettingsKey.networkPreferredWifiName: 'string',
    SettingsKey.networkLocalEndpoint: 'string',
    SettingsKey.mapCustomFrom: 'datetime',
    SettingsKey.mapCustomTo: 'datetime',
  };

  /// `bool`, `int`, `double`, `string`, `datetime`, `enum`, `list`, `map`, `semver` or `user`.
  static String appType(SettingsKey key) {
    final fixed = _nullableTypes[key];
    if (fixed != null) {
      return fixed;
    }
    return switch (defaultConfig.read(key)) {
      bool() => 'bool',
      int() => 'int',
      double() => 'double',
      String() => 'string',
      DateTime() => 'datetime',
      Enum() => 'enum',
      List() => 'list',
      Map() => 'map',
      SemVer() => 'semver',
      _ => 'string',
    };
  }

  static List<String>? appEnumValues(SettingsKey key) {
    final value = defaultConfig.read(key);
    return value is Enum ? [for (final item in _enums[value.runtimeType] ?? const <Enum>[]) item.name] : null;
  }

  static String storeType(StoreKey key) => switch (key.type) {
    const (bool) => 'bool',
    const (int) => 'int',
    const (String) => 'string',
    const (DateTime) => 'datetime',
    const (UserDto) => 'user',
    _ => 'string',
  };

  static Object? encodeApp(Object? value) => value is SemVer ? value.toString() : PluginJson.value(value);

  static Object? encodeStore(Object? value) => value is UserDto ? PluginJson.user(value) : PluginJson.value(value);

  /// Turns a plugin's JSON value into the Dart value of [key]. Null means "back to the default".
  static Object? decodeApp(SettingsKey key, Object? json) {
    if (json == null) {
      return null;
    }
    final String raw;
    if (json is List) {
      raw = jsonEncode([for (final item in json) '$item']);
    } else if (json is Map) {
      raw = jsonEncode({for (final entry in json.entries) '${entry.key}': '${entry.value}'});
    } else if (json is double && json == json.roundToDouble() && appType(key) == 'int') {
      raw = '${json.toInt()}';
    } else {
      raw = '$json';
    }
    try {
      return key.decode(raw);
    } catch (error) {
      throw PluginSettingException('Invalid value for ${appKey(key)}: $json');
    }
  }

  static Object? decodeStore(StoreKey key, Object? json) {
    if (json == null) {
      return null;
    }
    final Object? value = switch (key.type) {
      const (bool) => PluginArgs.boolean(json),
      const (int) => PluginArgs.integer(json),
      const (String) => json is String ? json : jsonEncode(json),
      const (DateTime) => PluginArgs.date(json),
      _ => throw PluginSettingException('${storeKey(key)} cannot be written by plugins'),
    };
    if (value == null) {
      throw PluginSettingException('Invalid value for ${storeKey(key)}: $json');
    }
    return value;
  }
}
