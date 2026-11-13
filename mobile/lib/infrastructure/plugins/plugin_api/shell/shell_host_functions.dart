import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/log.model.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/log_json.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/plugin_strings.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/plugin_theme.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_ids.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/backup/backup_album.provider.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/theme/theme_override.dart';
import 'package:logging/logging.dart';

/// A host function as the kernel registers it: the calling plugin's name and the JSON argument list.
typedef ShellHostFunction = Future<Object?> Function(String plugin, List<dynamic> args);

/// A host function call that cannot be done; the kernel answers `{ "success": false, "message" }`.
class ShellHostError implements Exception {
  const ShellHostError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The theme as the app currently draws it, for `theme.get`.
typedef ShellThemeState = ({ImmichTheme theme, ThemeMode mode, Brightness platformBrightness, String? fontFamily});

/// Logic of the shell's host functions (`nav.*`, `theme.*`, `strings.*`, `logs.*`, `app.*`, `backup.*`).
///
/// Plain Dart: everything app specific comes in through the constructor, so the kernel wiring (`shell_plugin_api.dart`)
/// only connects providers. Arguments follow `docs/plugins/shell.md`; each function accepts its documented positional
/// arguments or one object with the same names.
class ShellHostFunctions {
  ShellHostFunctions({
    required this.router,
    required this.themeController,
    required this.themeState,
    required this.strings,
    required this.setLocale,
    required this.openSettings,
    required this.settingsPages,
    required this.lifecycle,
    required this.backup,
    required this.backupAlbums,
    required this.currentUserId,
    this.resolvePluginPath,
    this.logService,
  });

  /// The app router (the root stack router).
  final StackRouter Function() router;
  final PluginThemeController themeController;
  final ShellThemeState Function() themeState;
  final PluginStrings strings;

  /// Changes the app language like the language settings page (through the `locale.set` hook).
  final Future<void> Function(Locale locale) setLocale;

  /// Opens the Settings page ([page] null), a built-in settings page (`preferences`, `backup`, ...) or a plugin
  /// settings page (`plugin:<name>/<id>`); false when [page] is unknown.
  final Future<bool> Function(String? page) openSettings;

  /// Every settings page id [openSettings] accepts, with titles.
  final List<Map<String, dynamic>> Function() settingsPages;
  final AppLifecycleState? Function() lifecycle;
  final BackupNotifier Function() backup;
  final BackupAlbumNotifier Function() backupAlbums;
  final String? Function() currentUserId;

  /// Turns a path inside a plugin's files (fonts in `theme.set`) into an absolute path.
  final String Function(String plugin, String path)? resolvePluginPath;

  /// The app log; defaults to [LogService.I].
  final LogService? logService;

  Map<String, ShellHostFunction> get functions => {
    ShellHostNames.navPush: _navPush,
    ShellHostNames.navPop: _navPop,
    ShellHostNames.navReplace: _navReplace,
    ShellHostNames.navReplaceAll: _navReplaceAll,
    ShellHostNames.navStack: _navStack,
    ShellHostNames.navRoutes: _navRoutes,
    ShellHostNames.themeGet: _themeGet,
    ShellHostNames.themeSet: _themeSet,
    ShellHostNames.stringsGet: _stringsGet,
    ShellHostNames.stringsSet: _stringsSet,
    ShellHostNames.stringsLocale: _stringsLocale,
    ShellHostNames.stringsSetLocale: _stringsSetLocale,
    ShellHostNames.logsWrite: _logsWrite,
    ShellHostNames.logsRead: _logsRead,
    ShellHostNames.logsClear: _logsClear,
    ShellHostNames.appOpenSettings: _appOpenSettings,
    ShellHostNames.appSettingsPages: (_, _) async => settingsPages(),
    ShellHostNames.appLifecycle: (_, _) async => {'state': lifecycle()?.name},
    ShellHostNames.backupStatus: (_, _) async => backup().statusJson(),
    ShellHostNames.backupStart: _backupStart,
    ShellHostNames.backupStop: _backupStop,
    ShellHostNames.backupAlbums: (_, _) async => backupAlbums().albumsJson(),
    ShellHostNames.backupSetAlbum: _backupSetAlbum,
  };

  /// Documentation strings for `kernel.registerHost(doc:)`.
  static const docs = {
    ShellHostNames.navPush: '[path | { path | route, wait }] -> true, or the popped result with wait',
    ShellHostNames.navPop: '[result?] -> bool',
    ShellHostNames.navReplace: '[path | { path | route }] -> true',
    ShellHostNames.navReplaceAll: '[[path, ...]] -> true (back to the home screen, then each path)',
    ShellHostNames.navStack: '[] -> [{ route, path, params, query }]',
    ShellHostNames.navRoutes: '[] -> [{ route, path }]',
    ShellHostNames.themeGet: '[] -> { mode, brightness, light, dark, fontFamily, override, own }',
    ShellHostNames.themeSet: '[override | null] -> true',
    ShellHostNames.stringsGet: '[{ keys?, locale? }] -> { locale, strings }',
    ShellHostNames.stringsSet: '[locale, { key: text } | null] -> true',
    ShellHostNames.stringsLocale: '[] -> { locale, supported }',
    ShellHostNames.stringsSetLocale: '[locale] -> true',
    ShellHostNames.logsWrite: '[level, message, { error?, stack?, logger? }?] -> true',
    ShellHostNames.logsRead: '[{ limit?, level?, logger?, since? }?] -> [LogV1]',
    ShellHostNames.logsClear: '[] -> true',
    ShellHostNames.appOpenSettings: '[page?] -> bool',
    ShellHostNames.appSettingsPages: '[] -> [{ id, title, plugin? }]',
    ShellHostNames.appLifecycle: '[] -> { state }',
    ShellHostNames.backupStatus: '[] -> { running, syncing, total, backedUp, remainder, processing, uploading, error }',
    ShellHostNames.backupStart: '[] -> true',
    ShellHostNames.backupStop: '[reason?] -> true',
    ShellHostNames.backupAlbums: '[] -> [{ id, name, assetCount, selection }]',
    ShellHostNames.backupSetAlbum: '[albumId, "selected" | "none" | "excluded"] -> true',
  };

  // ---- helpers -------------------------------------------------------------------------------------------------

  static Map<String, dynamic> _object(List<dynamic> args, [int index = 0]) =>
      args.length > index && args[index] is Map ? Map<String, dynamic>.from(args[index] as Map) : const {};

  static Object? _arg(List<dynamic> args, int index, String name) {
    final object = _object(args);
    if (object.isNotEmpty && args.length == 1) {
      return object[name];
    }
    return args.length > index ? args[index] : null;
  }

  String _targetPath(List<dynamic> args) {
    final first = args.isEmpty ? null : args.first;
    if (first is String && first.isNotEmpty) {
      return first;
    }
    final object = _object(args);
    final path = object['path'];
    if (path is String && path.isNotEmpty) {
      return path;
    }
    final route = object['route'];
    if (route is String && route.isNotEmpty) {
      for (final config in router().root.routeCollection.routes) {
        if (config.name == route) {
          return config.path;
        }
      }
      throw ShellHostError('Unknown route $route');
    }
    throw const ShellHostError('A path or route is required');
  }

  // ---- nav.* -----------------------------------------------------------------------------------------------------

  Future<Object?> _navPush(String plugin, List<dynamic> args) async {
    final path = _targetPath(args);
    final pushed = router().root.pushPath<Object?>(path);
    if (_object(args)['wait'] == true) {
      return pushed;
    }
    unawaited(pushed);
    return true;
  }

  Future<Object?> _navPop(String plugin, List<dynamic> args) =>
      router().root.maybePopTop<Object?>(args.isEmpty ? null : args.first);

  Future<Object?> _navReplace(String plugin, List<dynamic> args) async {
    unawaited(router().root.replacePath<Object?>(_targetPath(args)));
    return true;
  }

  Future<Object?> _navReplaceAll(String plugin, List<dynamic> args) async {
    final paths = args.isNotEmpty && args.first is List ? [for (final path in args.first as List) '$path'] : <String>[];
    final root = router().root;
    root.popUntilRoot();
    for (final path in paths) {
      unawaited(root.pushPath<Object?>(path));
    }
    return true;
  }

  Future<Object?> _navStack(String plugin, List<dynamic> args) async => [
    for (final data in router().root.stackData)
      {
        'route': data.name,
        'path': data.match,
        'params': {for (final e in data.params.rawMap.entries) e.key: '${e.value}'},
        'query': {for (final e in data.queryParams.rawMap.entries) e.key: '${e.value}'},
      },
  ];

  Future<Object?> _navRoutes(String plugin, List<dynamic> args) async => [
    for (final config in router().root.routeCollection.routes) {'route': config.name, 'path': config.path},
  ];

  // ---- theme.* ---------------------------------------------------------------------------------------------------

  Future<Object?> _themeGet(String plugin, List<dynamic> args) async {
    final state = themeState();
    final brightness = switch (state.mode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system => state.platformBrightness,
    };
    return {
      'mode': state.mode.name,
      'brightness': brightness.name,
      'light': colorSchemeToJson(state.theme.light),
      'dark': colorSchemeToJson(state.theme.dark),
      'fontFamily': state.fontFamily,
      'override': themeController.effective.toJson(),
      'own': themeController.runtime[plugin]?.toJson(),
    };
  }

  Future<Object?> _themeSet(String plugin, List<dynamic> args) async {
    final json = args.isEmpty ? null : args.first;
    if (json == null) {
      themeController.setRuntime(plugin, null);
      PluginHooks.emit(ShellEvents.themeChanged, () => {'plugin': plugin, 'override': null});
      return true;
    }
    if (json is! Map) {
      throw const ShellHostError('theme.set expects an object or null');
    }
    final spec = ThemeOverrideSpec.fromJson(json);
    if (spec.fonts.isNotEmpty) {
      final resolve = resolvePluginPath;
      await themeController.loadFonts({
        for (final MapEntry(:key, :value) in spec.fonts.entries)
          key: resolve == null || value.startsWith('/') ? value : resolve(plugin, value),
      });
    }
    themeController.setRuntime(plugin, spec);
    PluginHooks.emit(ShellEvents.themeChanged, () => {'plugin': plugin, 'override': spec.toJson()});
    return true;
  }

  // ---- strings.* -------------------------------------------------------------------------------------------------

  Future<Object?> _stringsGet(String plugin, List<dynamic> args) async {
    final object = _object(args);
    final localeName = object['locale'];
    final locale = localeName is String ? _parseLocale(localeName) : (strings.currentLocale ?? strings.fallbackLocale);
    final keys = PluginArgs.strings(object['keys']);
    if (keys.isEmpty) {
      return {'locale': locale.toString(), 'strings': strings.overrides.forLocale(locale)};
    }
    return {
      'locale': locale.toString(),
      'strings': {for (final key in keys) key: await strings.lookup(key, locale)},
    };
  }

  Future<Object?> _stringsSet(String plugin, List<dynamic> args) async {
    final locale = _arg(args, 0, 'locale');
    final map = _arg(args, 1, 'strings');
    if (locale is! String || locale.isEmpty) {
      throw const ShellHostError('strings.set expects a locale ("*" for every language)');
    }
    if (map != null && map is! Map) {
      throw const ShellHostError('strings.set expects { key: text } or null');
    }
    strings.overrides.setRuntime(
      plugin,
      locale,
      map == null ? null : {for (final MapEntry(:key, :value) in (map as Map).entries) '$key': '$value'},
    );
    PluginHooks.emit(ShellEvents.stringsChanged, () => {'plugin': plugin, 'locale': locale});
    return true;
  }

  Future<Object?> _stringsLocale(String plugin, List<dynamic> args) async => {
    'locale': (strings.currentLocale ?? strings.fallbackLocale).toString(),
    'fallback': strings.fallbackLocale.toString(),
  };

  Future<Object?> _stringsSetLocale(String plugin, List<dynamic> args) async {
    final name = _arg(args, 0, 'locale');
    if (name is! String || name.isEmpty) {
      throw const ShellHostError('strings.setLocale expects a locale');
    }
    await setLocale(_parseLocale(name));
    return true;
  }

  static Locale _parseLocale(String name) {
    final parts = name.replaceAll('-', '_').split('_');
    if (parts.length == 1) {
      return Locale(parts.first);
    }
    final second = parts[1];
    final isScript = second.length == 4;
    return Locale.fromSubtags(
      languageCode: parts.first,
      scriptCode: isScript ? second : null,
      countryCode: isScript ? (parts.length > 2 ? parts[2] : null) : second,
    );
  }

  // ---- logs.* ----------------------------------------------------------------------------------------------------

  Future<Object?> _logsWrite(String plugin, List<dynamic> args) async {
    final level = parseLogLevel(_arg(args, 0, 'level')) ?? LogLevel.info;
    final message = _arg(args, 1, 'message');
    final extra = args.length > 2 ? _object(args, 2) : _object(args);
    final loggerName = extra['logger'] is String ? 'plugin.$plugin.${extra['logger']}' : 'plugin.$plugin';
    final stack = extra['stack'];
    Logger(loggerName).log(
      loggingLevelOf(level),
      '${message ?? ''}',
      extra['error'],
      stack is String && stack.isNotEmpty ? StackTrace.fromString(stack) : null,
    );
    return true;
  }

  Future<Object?> _logsRead(String plugin, List<dynamic> args) async {
    final options = _object(args);
    final limit = PluginArgs.integer(options['limit']) ?? PluginArgs.integer(args.isNotEmpty ? args.first : null);
    final minimum = parseLogLevel(options['level']);
    final logger = PluginArgs.string(options['logger']);
    final since = PluginArgs.date(options['since']);
    final messages = await (logService ?? LogService.I).getMessages();
    final result = <Map<String, dynamic>>[];
    for (final message in messages) {
      if (minimum != null && message.level.index < minimum.index) {
        continue;
      }
      if (logger != null && !(message.logger?.startsWith(logger) ?? false)) {
        continue;
      }
      if (since != null && message.createdAt.isBefore(since)) {
        continue;
      }
      result.add(logMessageToJson(message));
      if (limit != null && result.length >= limit) {
        break;
      }
    }
    return result;
  }

  Future<Object?> _logsClear(String plugin, List<dynamic> args) async {
    await (logService ?? LogService.I).clearLogs();
    PluginHooks.emit(ShellEvents.logsCleared, () => {'plugin': plugin});
    return true;
  }

  // ---- app.* -----------------------------------------------------------------------------------------------------

  Future<Object?> _appOpenSettings(String plugin, List<dynamic> args) {
    final page = _arg(args, 0, 'page');
    return openSettings(page is String && page.isNotEmpty ? page : null);
  }

  // ---- backup.* --------------------------------------------------------------------------------------------------

  Future<Object?> _backupStart(String plugin, List<dynamic> args) async {
    final userId = currentUserId();
    if (userId == null) {
      throw const ShellHostError('No signed-in user');
    }
    unawaited(backup().startForegroundBackup(userId));
    return true;
  }

  Future<Object?> _backupStop(String plugin, List<dynamic> args) async {
    final reason = _arg(args, 0, 'reason');
    backup().stopForegroundBackup(reason: reason is String && reason.isNotEmpty ? reason : 'stopped by $plugin');
    return true;
  }

  Future<Object?> _backupSetAlbum(String plugin, List<dynamic> args) async {
    final albumId = _arg(args, 0, 'albumId');
    final selection = _arg(args, 1, 'selection');
    final notifier = backupAlbums();
    final album = albumId is String ? notifier.albumById(albumId) : null;
    if (album == null) {
      throw ShellHostError('Unknown device album $albumId');
    }
    switch (selection) {
      case 'selected':
        await notifier.selectAlbum(album);
      case 'none':
        await notifier.deselectAlbum(album);
      case 'excluded':
        await notifier.excludeAlbum(album);
      default:
        throw const ShellHostError('selection must be "selected", "none" or "excluded"');
    }
    return true;
  }
}

/// `app.resumed`, `app.inactive`, `app.paused`, `app.hidden` and `app.detached` for an app lifecycle change.
void emitAppLifecycle(AppLifecycleState state) {
  final event = switch (state) {
    AppLifecycleState.resumed => ShellEvents.appResumed,
    AppLifecycleState.inactive => ShellEvents.appInactive,
    AppLifecycleState.paused => ShellEvents.appPaused,
    AppLifecycleState.hidden => ShellEvents.appHidden,
    AppLifecycleState.detached => ShellEvents.appDetached,
  };
  PluginHooks.emit(event, () => {'state': state.name});
}

/// Forwards app log records to plugins as `log.recorded`, batched to at most one event per second.
///
/// [redact] removes secrets from texts (the app log redacts server addresses and tokens the same way).
class LogEventForwarder {
  LogEventForwarder(Stream<LogRecord> records, {this.redact}) {
    _subscription = records.listen(_onRecord);
  }

  final String Function(String text)? redact;
  late final StreamSubscription<LogRecord> _subscription;
  final List<Map<String, dynamic>> _pending = [];
  Timer? _timer;

  void _onRecord(LogRecord record) {
    if (!PluginHooks.listens(ShellEvents.logRecorded)) {
      return;
    }
    final clean = redact ?? (String text) => text;
    _pending.add({
      'level': record.level.name.toLowerCase(),
      'message': clean(record.message),
      'logger': record.loggerName,
      if (record.error != null) 'error': clean('${record.error}'),
      'createdAt': record.time.toUtc().toIso8601String(),
    });
    if (_pending.length > 200) {
      _pending.removeRange(0, _pending.length - 200);
    }
    _timer ??= Timer(const Duration(seconds: 1), _flush);
  }

  void _flush() {
    _timer = null;
    if (_pending.isEmpty) {
      return;
    }
    final records = [..._pending];
    _pending.clear();
    PluginHooks.emit(ShellEvents.logRecorded, () => {'records': records});
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _subscription.cancel();
  }
}
