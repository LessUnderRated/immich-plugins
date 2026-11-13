import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';

/// Raw database access: `db.query`, `db.execute`, `db.batch`, `db.tables`, `db.notify`.
///
/// Writes go through Drift (`customUpdate` with the written tables, or `customStatement` plus a notification), so
/// every stream query of the app (timeline, albums, counts) updates right away. `{ "database": "logs" }` selects
/// the log database instead of the main one.
class DbHostApi implements DataHostModule {
  final GeneratedDatabase _main;
  final GeneratedDatabase? _logs;

  DbHostApi(this._main, {this._logs});

  @override
  late final Map<String, DataHostFunction> functions = {
    'db.query': (plugin, args) => query(HostArgs(args).text(0, 'sql'), _list(args, 1), HostArgs(args).map(2)),
    'db.execute': (plugin, args) =>
        execute(HostArgs(args).text(0, 'sql'), _list(args, 1), HostArgs(args).map(2), plugin: plugin),
    'db.batch': (plugin, args) => batch(_list(args, 0), HostArgs(args).map(1), plugin: plugin),
    'db.tables': (plugin, args) => tables(HostArgs(args).map(0)),
    'db.notify': (plugin, args) => notify(PluginArgs.strings(HostArgs(args)[0]), HostArgs(args).map(1)),
  };

  @override
  Map<String, String> get docs => const {
    'db.query': '[sql, args?, { database? }] -> [{ column: value }] (blobs as base64)',
    'db.execute': '[sql, args?, { database?, tables? }] -> { rowsAffected, tables } (notifies the app)',
    'db.batch': '[[{ sql, args? }], { database? }] -> { results: [{ rowsAffected }], tables } in one transaction',
    'db.tables': '[{ database? }] -> [{ name, type, sql, columns: [{ name, type, notNull, defaultValue, primaryKey }] }]',
    'db.notify': '[tables, { database? }] -> null (refreshes app queries on those tables)',
  };

  static List<dynamic> _list(List<dynamic> args, int index) =>
      index < args.length && args[index] is List ? args[index] as List : const [];

  GeneratedDatabase _database(Map<String, dynamic> options) {
    final name = options['database'] ?? 'main';
    return switch (name) {
      'main' => _main,
      'logs' => _logs ?? (throw const DataHostException.notFound('The log database is not available')),
      _ => throw DataHostException.badRequest('Unknown database $name'),
    };
  }

  static Variable<Object> _variable(Object? value) => switch (value) {
    null => const Variable<Object>(null),
    bool() => Variable<Object>(value ? 1 : 0),
    int() || double() || String() => Variable<Object>(value),
    {'blob': final String base64} => Variable<Object>(base64Decode(base64)),
    List() || Map() => Variable<Object>(jsonEncode(value)),
    _ => Variable<Object>('$value'),
  };

  static Object? _cell(Object? value) => value is Uint8List ? base64Encode(value) : value;

  Future<List<Map<String, dynamic>>> query(String sql, List<dynamic> args, Map<String, dynamic> options) async {
    final rows = await _database(options).customSelect(sql, variables: [for (final arg in args) _variable(arg)]).get();
    return [
      for (final row in rows) {for (final entry in row.data.entries) entry.key: _cell(entry.value)},
    ];
  }

  static final _writePattern = RegExp(
    r'''^\s*(?:with\b[\s\S]*?\)\s*)?(?:insert(?:\s+or\s+\w+)?\s+into|replace\s+into|update(?:\s+or\s+\w+)?|delete\s+from)\s+["`\[]?([A-Za-z_][\w]*)''',
    caseSensitive: false,
  );

  static final _readPattern = RegExp(r'^\s*(?:select|pragma\s+\w+\s*$|explain)\b', caseSensitive: false);

  /// Runs one statement; runs as `db.execute` (a plugin may rewrite `sql`/`args` or cancel).
  Future<Map<String, dynamic>> execute(
    String sql,
    List<dynamic> args,
    Map<String, dynamic> options, {
    String? plugin,
  }) => PluginHooks.run<Map<String, dynamic>>(
    DataHooks.dbExecute,
    () => {'sql': sql, 'args': args, 'database': options['database'] ?? 'main', 'plugin': plugin},
    () => _execute(sql, args, options),
    withArgs: (changed) => _execute(PluginArgs.string(changed['sql']) ?? sql, _listOf(changed['args']), options),
    encode: (result) => result,
    decode: (json) => json is Map ? Map<String, dynamic>.from(json) : const {},
  );

  static List<dynamic> _listOf(Object? value) => value is List ? value : const [];

  Future<Map<String, dynamic>> _execute(String sql, List<dynamic> args, Map<String, dynamic> options) async {
    if (_readPattern.hasMatch(sql)) {
      throw const DataHostException.badRequest('Use db.query for statements that return rows');
    }
    final database = _database(options);
    final variables = [for (final arg in args) _variable(arg)];
    final named = {...PluginArgs.strings(options['tables']), ?_writePattern.firstMatch(sql)?.group(1)};
    final tables = _tables(database, named);

    if (tables.isNotEmpty) {
      final rows = await database.customUpdate(
        sql,
        variables: variables,
        updates: tables,
        updateKind: _updateKind(sql),
      );
      return {
        'rowsAffected': rows,
        'tables': [for (final table in tables) table.entityName],
      };
    }

    // DDL or a statement on a table Drift does not manage: run it and refresh everything that might depend on it.
    await database.customStatement(sql, [for (final variable in variables) variable.value]);
    database.notifyUpdates({for (final table in database.allTables) TableUpdate.onTable(table)});
    return {'rowsAffected': null, 'tables': named.toList()};
  }

  static UpdateKind? _updateKind(String sql) {
    final verb = sql.trimLeft().toLowerCase();
    if (verb.startsWith('delete')) {
      return UpdateKind.delete;
    }
    if (verb.startsWith('update')) {
      return UpdateKind.update;
    }
    if (verb.startsWith('insert') || verb.startsWith('replace')) {
      return UpdateKind.insert;
    }
    return null;
  }

  static Set<TableInfo> _tables(GeneratedDatabase database, Set<String> names) => {
    for (final table in database.allTables)
      if (names.contains(table.actualTableName)) table,
  };

  /// Runs several statements in one transaction; any failure rolls all of them back.
  Future<Map<String, dynamic>> batch(List<dynamic> statements, Map<String, dynamic> options, {String? plugin}) async {
    final database = _database(options);
    final results = <Map<String, dynamic>>[];
    final touched = <String>{};
    await database.transaction(() async {
      for (final statement in statements) {
        final map = statement is Map ? Map<String, dynamic>.from(statement) : <String, dynamic>{'sql': statement};
        final sql = PluginArgs.string(map['sql']);
        if (sql == null) {
          throw const DataHostException.badRequest('Every batch entry needs sql');
        }
        final result = await execute(sql, _listOf(map['args']), options, plugin: plugin);
        results.add(result);
        touched.addAll(PluginArgs.strings(result['tables']));
      }
    });
    return {'results': results, 'tables': touched.toList()};
  }

  Future<List<Map<String, dynamic>>> tables(Map<String, dynamic> options) async {
    final database = _database(options);
    final managed = {for (final table in database.allTables) table.actualTableName};
    final entries = await database
        .customSelect(
          "SELECT name, type, sql FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' "
          'ORDER BY name',
        )
        .get();
    return [
      for (final entry in entries)
        {
          'name': entry.read<String>('name'),
          'type': entry.read<String>('type'),
          'sql': entry.readNullable<String>('sql'),
          'managed': managed.contains(entry.read<String>('name')),
          'columns': [
            for (final column in await database
                .customSelect("SELECT * FROM pragma_table_info(?)", variables: [Variable(entry.read<String>('name'))])
                .get())
              {
                'name': column.read<String>('name'),
                'type': column.read<String>('type'),
                'notNull': column.read<int>('notnull') == 1,
                'defaultValue': column.readNullable<String>('dflt_value'),
                'primaryKey': column.read<int>('pk') > 0,
              },
          ],
        },
    ];
  }

  /// Tells the app that [tableNames] changed (e.g. after writing through another connection).
  Future<void> notify(List<String> tableNames, Map<String, dynamic> options) async {
    final database = _database(options);
    final tables = tableNames.isEmpty ? database.allTables.toSet() : _tables(database, tableNames.toSet());
    database.notifyUpdates({for (final table in tables) TableUpdate.onTable(table)});
  }
}

/// Emits `db.changed` (`{ tables: [...] }`) when tables of the main database change, coalesced over [window].
/// Nothing is listened to while no plugin subscribes to the event.
class DbChangeWatcher {
  final GeneratedDatabase _db;
  final Duration window;
  StreamSubscription<Set<TableUpdate>>? _subscription;
  final Set<String> _pending = {};
  Timer? _timer;

  DbChangeWatcher(this._db, {this.window = const Duration(milliseconds: 250)});

  /// Starts or stops listening depending on whether a plugin listens to `db.changed`. Call after plugins change.
  void refresh() {
    final wanted = PluginHooks.listens(DataEvents.dbChanged);
    if (wanted && _subscription == null) {
      _subscription = _db.tableUpdates(const TableUpdateQuery.any()).listen(_onUpdates);
    } else if (!wanted && _subscription != null) {
      unawaited(_subscription!.cancel());
      _subscription = null;
    }
  }

  void _onUpdates(Set<TableUpdate> updates) {
    _pending.addAll(updates.map((update) => update.table));
    _timer ??= Timer(window, () {
      _timer = null;
      final tables = _pending.toList()..sort();
      _pending.clear();
      PluginHooks.emit(DataEvents.dbChanged, () => {'database': 'main', 'tables': tables});
    });
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _subscription?.cancel();
    _subscription = null;
  }
}
