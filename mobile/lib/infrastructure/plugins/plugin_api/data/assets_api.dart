import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';
import 'package:immich_mobile/infrastructure/repositories/app_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/device_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/device_tag.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/device_trash.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/private_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/services/action.service.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

/// Asset host functions (`assets.*`) over device assets (MediaStore, the local table) and server assets (the remote
/// table and the server API). Every change runs through the same service hooks and events as the app's own actions.
///
/// Bulk operations take one id or a list and answer `{ count, ids, unsupported?, unknown?, errors? }`: `unsupported`
/// lists ids the operation does not apply to (e.g. archiving a device-only asset), `unknown` ids that exist nowhere.
class AssetsHostApi implements DataHostModule {
  static const _channel = MethodChannel('immich/device_media');

  final Drift _db;
  final AssetService _assets;
  final ActionService _actions;
  final DeviceAlbumRepository _deviceAlbums;
  final DeviceTrashRepository _trash;
  final PrivateAlbumRepository _private;
  final DeviceTagRepository _tags;
  final AppAlbumRepository _appAlbums;
  final StorageRepository _storage;
  final String? Function() _currentUserId;

  /// Rescans the device library after device-side changes (moves, metadata) so the app shows them.
  final Future<void> Function() _refreshLibrary;

  const AssetsHostApi(
    this._db,
    this._assets,
    this._actions,
    this._deviceAlbums,
    this._trash,
    this._private,
    this._tags,
    this._appAlbums,
    this._storage,
    this._currentUserId,
    this._refreshLibrary,
  );

  @override
  Map<String, DataHostFunction> get functions => {
    'assets.query': (plugin, args) => query(HostArgs(args).map(0)),
    'assets.count': (plugin, args) => count(HostArgs(args).map(0)),
    'assets.get': (plugin, args) => get(HostArgs(args).text(0, 'id')),
    'assets.file': (plugin, args) => file(HostArgs(args).text(0, 'id'), HostArgs(args).map(1)),
    'assets.favorite': (plugin, args) => favorite(_ids(args), HostArgs(args).boolean(1, 'favorite')),
    'assets.archive': (plugin, args) =>
        setVisibility(_ids(args), HostArgs(args).boolean(1, 'archive') ? AssetVisibility.archive : .timeline),
    'assets.setVisibility': (plugin, args) => setVisibility(
      _ids(args),
      PluginJson.parseVisibility(HostArgs(args)[1]) ??
          (throw const DataHostException.badRequest('visibility must be timeline, archive, hidden or locked')),
    ),
    'assets.trash': (plugin, args) => trash(_ids(args)),
    'assets.restore': (plugin, args) => restore(_ids(args)),
    'assets.delete': (plugin, args) => delete(_ids(args), permanent: HostArgs(args).map(1).flag('permanent') ?? false),
    'assets.setDate': (plugin, args) => setDate(_ids(args), HostArgs(args).text(1, 'dateTime')),
    'assets.setLocation': (plugin, args) {
      final location = HostArgs(args).map(1);
      final latitude = location.real('latitude');
      final longitude = location.real('longitude');
      if (latitude == null || longitude == null) {
        throw const DataHostException.badRequest('Location needs latitude and longitude');
      }
      return setLocation(_ids(args), latitude, longitude);
    },
    'assets.setDescription': (plugin, args) => setDescription(_ids(args), HostArgs(args).optText(1) ?? ''),
    'assets.setRating': (plugin, args) => setRating(_ids(args), PluginArgs.integer(HostArgs(args)[1])),
    'assets.stack': (plugin, args) => stack(_ids(args)),
    'assets.unstack': (plugin, args) => unstack(_ids(args)),
    'assets.move': (plugin, args) => move(_ids(args), HostArgs(args).text(1, 'folder')),
    'assets.setPrivate': (plugin, args) => setPrivate(_ids(args), HostArgs(args).boolean(1, 'private')),
    'assets.tag': (plugin, args) async => {
      'count': await _tags.assign(_ids(args), HostArgs(args).ids(1, 'tags')),
    },
    'assets.untag': (plugin, args) async {
      final ids = _ids(args);
      var count = 0;
      for (final tag in HostArgs(args).ids(1, 'tags')) {
        count += await _tags.unassign(tag, ids);
      }
      return {'count': count};
    },
    'assets.tags': (plugin, args) async => [
      for (final tag in await _tags.forAsset(HostArgs(args).text(0, 'id'))) PluginJson.tag(tag),
    ],
    'trash.list': (plugin, args) => trashList(HostArgs(args).map(0)),
    'trash.empty': (plugin, args) => emptyTrash(HostArgs(args).map(0)),
  };

  @override
  Map<String, String> get docs => const {
    'assets.query':
        '[{ source: "local" | "remote" | "all", ids?, type?, favorite?, from?, to?, name?, albumId?, tag?, '
        'hasLocation?, private: "exclude" | "include" | "only", visibility?, trashed?, orderBy: "createdAt" | '
        '"updatedAt" | "name", order: "desc" | "asc", limit = 100, offset = 0 }] -> [AssetLite]',
    'assets.count': '[filter] -> int (same filter as assets.query, without limit)',
    'assets.get': '[id] -> AssetLite + { exif?, tags, private, albumIds } (404 when unknown)',
    'assets.file': '[id, { motion? }] -> { path, size } (device assets; 404 when the file is not on the device)',
    'assets.favorite': '[ids, favorite] -> bulk result',
    'assets.archive': '[ids, archive] -> bulk result (server assets)',
    'assets.setVisibility': '[ids, "timeline" | "archive" | "hidden" | "locked"] -> bulk result (server assets)',
    'assets.trash': '[ids] -> bulk result (device: system trash; server: server trash)',
    'assets.restore': '[ids] -> bulk result (device system trash and server trash)',
    'assets.delete': '[ids, { permanent? }] -> bulk result (without permanent: same as trash)',
    'assets.setDate': '[ids, isoDateTime] -> bulk result',
    'assets.setLocation': '[ids, { latitude, longitude }] -> bulk result',
    'assets.setDescription': '[ids, text] -> bulk result',
    'assets.setRating': '[ids, rating 0-5 | null] -> bulk result (server assets)',
    'assets.stack': '[ids] -> bulk result (server assets; the first id becomes the primary)',
    'assets.unstack': '[ids] -> bulk result (asset ids or stack ids)',
    'assets.move': '[ids, folder] -> bulk result (device assets; folder like "Pictures/Trips")',
    'assets.setPrivate': '[ids, private] -> bulk result',
    'assets.tag': '[ids, tags] -> { count } (device tags, created when missing)',
    'assets.untag': '[ids, tags] -> { count }',
    'assets.tags': '[id] -> [Tag]',
    'trash.list': '[{ source: "device" | "remote" = "device" }] -> device: [{ id, name, type, expiresAt, takenAt }], '
        'remote: [AssetLite]',
    'trash.empty': '[{ source: "device" | "remote" = "device" }] -> { count } (device: one system confirmation)',
  };

  static List<String> _ids(List<dynamic> args) => HostArgs(args).ids(0, 'ids');

  // ---- reading -------------------------------------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> query(Map<String, dynamic> filter) async =>
      [for (final asset in await _query(filter)) PluginJson.asset(asset)];

  Future<int> count(Map<String, dynamic> filter) async =>
      (await _query({...filter, 'limit': null, 'offset': 0}, countOnly: true)).length;

  Future<List<BaseAsset>> _query(Map<String, dynamic> filter, {bool countOnly = false}) async {
    final source = filter.text('source') ?? 'local';
    final limit = countOnly ? null : (filter.integer('limit') ?? 100).clamp(1, 5000);
    final offset = countOnly ? 0 : (filter.integer('offset') ?? 0).clamp(0, 1 << 31);
    final window = limit == null ? null : limit + offset;
    final results = <BaseAsset>[
      if (source == 'local' || source == 'all') ...await _queryLocal(filter, window),
      if (source == 'remote' || source == 'all') ...await _queryRemote(filter, window, remoteOnly: source == 'all'),
    ];
    if (source == 'all') {
      results.sort(_comparator(filter));
    }
    final end = limit == null ? results.length : (offset + limit).clamp(0, results.length);
    return offset >= results.length ? const [] : results.sublist(offset, end);
  }

  static int Function(BaseAsset a, BaseAsset b) _comparator(Map<String, dynamic> filter) {
    final ascending = filter.text('order') == 'asc';
    int compare(BaseAsset a, BaseAsset b) => switch (filter.text('orderBy')) {
      'name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      'updatedAt' => a.updatedAt.compareTo(b.updatedAt),
      _ => a.createdAt.compareTo(b.createdAt),
    };
    return ascending ? compare : (a, b) => compare(b, a);
  }

  Future<Set<String>?> _scopeIds(Map<String, dynamic> filter) async {
    Set<String>? scope = filter['ids'] == null ? null : filter.strings('ids').toSet();
    final albumId = filter.text('albumId');
    if (albumId != null) {
      final app = await _appAlbums.get(albumId);
      if (app != null) {
        scope = {...?scope?.intersection(app.assetIds.toSet()), if (scope == null) ...app.assetIds};
      }
    }
    final tag = filter.text('tag');
    if (tag != null) {
      final tagged = (await _tags.assetsWith(tag, includeChildren: true)).toSet();
      scope = scope == null ? tagged : scope.intersection(tagged);
    }
    return scope;
  }

  Future<List<LocalAsset>> _queryLocal(Map<String, dynamic> filter, int? window) async {
    final scope = await _scopeIds(filter);
    final albumId = filter.text('albumId');
    final isAppAlbum = albumId != null && await _appAlbums.get(albumId) != null;
    final privateMode = filter.text('private') ?? 'exclude';
    final privateIds = await _private.ids();
    final table = _db.localAssetEntity;
    final query = _db.select(table)
      ..where((row) {
        final conditions = <Expression<bool>>[
          if (scope != null) row.id.isIn(scope),
          if (privateMode == 'exclude' && privateIds.isNotEmpty) row.id.isNotIn(privateIds),
          if (privateMode == 'only') row.id.isIn(privateIds),
          ..._commonConditions(filter, type: row.type, createdAt: row.createdAt, name: row.name),
          if (filter.flag('favorite') case final bool favorite) row.isFavorite.equals(favorite),
          if (filter.flag('hasLocation') case final bool hasLocation)
            hasLocation ? row.latitude.isNotNull() : row.latitude.isNull(),
          if (albumId != null && !isAppAlbum)
            row.id.isInQuery(
              _db.selectOnly(_db.localAlbumAssetEntity)
                ..addColumns([_db.localAlbumAssetEntity.assetId])
                ..where(_db.localAlbumAssetEntity.albumId.equals(albumId)),
            ),
        ];
        return conditions.isEmpty ? const Constant(true) : Expression.and(conditions);
      })
      ..orderBy([(row) => _ordering(filter, row.createdAt, row.updatedAt, row.name), (row) => OrderingTerm.asc(row.id)]);
    if (window != null) {
      query.limit(window);
    }
    return [for (final row in await query.get()) row.toDto()];
  }

  Future<List<RemoteAsset>> _queryRemote(Map<String, dynamic> filter, int? window, {required bool remoteOnly}) async {
    final scope = await _scopeIds(filter);
    final albumId = filter.text('albumId');
    final visibility = filter.text('visibility') ?? 'timeline';
    final trashed = filter.flag('trashed') ?? false;
    final table = _db.remoteAssetEntity;
    final query = _db.select(table)
      ..where((row) {
        final conditions = <Expression<bool>>[
          if (scope != null) row.id.isIn(scope),
          trashed ? row.deletedAt.isNotNull() : row.deletedAt.isNull(),
          if (visibility != 'any')
            row.visibility.equalsValue(PluginJson.parseVisibility(visibility) ?? AssetVisibility.timeline),
          ..._commonConditions(filter, type: row.type, createdAt: row.createdAt, name: row.name),
          if (filter.flag('favorite') case final bool favorite) row.isFavorite.equals(favorite),
          if (albumId != null)
            row.id.isInQuery(
              _db.selectOnly(_db.remoteAlbumAssetEntity)
                ..addColumns([_db.remoteAlbumAssetEntity.assetId])
                ..where(_db.remoteAlbumAssetEntity.albumId.equals(albumId)),
            ),
          if (remoteOnly)
            row.checksum.isNotInQuery(
              _db.selectOnly(_db.localAssetEntity)
                ..addColumns([_db.localAssetEntity.checksum])
                ..where(_db.localAssetEntity.checksum.isNotNull()),
            ),
        ];
        return Expression.and(conditions);
      })
      ..orderBy([(row) => _ordering(filter, row.createdAt, row.updatedAt, row.name), (row) => OrderingTerm.asc(row.id)]);
    if (window != null) {
      query.limit(window);
    }
    return [for (final row in await query.get()) row.toDto()];
  }

  static List<Expression<bool>> _commonConditions(
    Map<String, dynamic> filter, {
    required GeneratedColumnWithTypeConverter<AssetType, int> type,
    required GeneratedColumn<DateTime> createdAt,
    required GeneratedColumn<String> name,
  }) => [
    if (PluginJson.parseAssetType(filter['type']) case final AssetType assetType) type.equalsValue(assetType),
    if (filter.date('from') case final DateTime from) createdAt.isBiggerOrEqualValue(from),
    if (filter.date('to') case final DateTime to) createdAt.isSmallerThanValue(to),
    if (filter.text('name') case final String text) name.lower().contains(text.toLowerCase()),
  ];

  static OrderingTerm _ordering(
    Map<String, dynamic> filter,
    Expression<DateTime> createdAt,
    Expression<DateTime> updatedAt,
    Expression<String> name,
  ) {
    final mode = filter.text('order') == 'asc' ? OrderingMode.asc : OrderingMode.desc;
    return switch (filter.text('orderBy')) {
      'name' => OrderingTerm(expression: name.lower(), mode: mode),
      'updatedAt' => OrderingTerm(expression: updatedAt, mode: mode),
      _ => OrderingTerm(expression: createdAt, mode: mode),
    };
  }

  Future<Map<String, dynamic>> get(String id) async {
    final local = await (_db.select(_db.localAssetEntity)..where((row) => row.id.equals(id))).getSingleOrNull();
    final remote = local != null
        ? null
        : await (_db.select(_db.remoteAssetEntity)..where((row) => row.id.equals(id))).getSingleOrNull();
    final BaseAsset? asset = local?.toDto() ?? remote?.toDto();
    if (asset == null) {
      throw DataHostException.notFound('Asset $id not found');
    }
    final exif = remote == null ? null : await _assets.watchExif(asset).first;
    final deviceAlbums = local == null
        ? const <String>[]
        : await (_db.selectOnly(_db.localAlbumAssetEntity)
                ..addColumns([_db.localAlbumAssetEntity.albumId])
                ..where(_db.localAlbumAssetEntity.assetId.equals(id)))
              .map((row) => row.read(_db.localAlbumAssetEntity.albumId)!)
              .get();
    return {
      ...PluginJson.asset(asset),
      'exif': exif == null ? null : PluginJson.exif(exif),
      'tags': [for (final tag in await _tags.forAsset(id)) PluginJson.tag(tag)],
      'private': (await _private.ids()).contains(id),
      'albumIds': [
        ...deviceAlbums,
        for (final album in await _appAlbums.list())
          if (album.assetIds.contains(id)) album.id,
      ],
    };
  }

  Future<Map<String, dynamic>> file(String id, Map<String, dynamic> options) async {
    final local = await _assets.getLocalAsset(id);
    if (local == null) {
      throw DataHostException.notFound('Asset $id is not on this device');
    }
    final file = options.flag('motion') == true
        ? await _storage.getMotionFileForAsset(local)
        : await _storage.getFileForAsset(id);
    if (file == null) {
      throw DataHostException.notFound('The file of $id is not available on this device');
    }
    return {'path': file.path, 'size': await file.length(), 'name': local.name};
  }

  // ---- changes -------------------------------------------------------------------------------------------------

  /// Splits [ids] into device assets, server assets and unknown ids.
  Future<({List<LocalAsset> local, List<RemoteAsset> remote, List<String> unknown})> _classify(List<String> ids) async {
    final local = [
      for (final row in await (_db.select(_db.localAssetEntity)..where((row) => row.id.isIn(ids))).get()) row.toDto(),
    ];
    final localIds = {for (final asset in local) asset.id};
    final rest = ids.where((id) => !localIds.contains(id)).toList();
    final remote = rest.isEmpty
        ? const <RemoteAsset>[]
        : [
            for (final row in await (_db.select(_db.remoteAssetEntity)..where((row) => row.id.isIn(rest))).get())
              row.toDto(),
          ];
    final known = {...localIds, for (final asset in remote) asset.id};
    return (local: local, remote: remote, unknown: ids.where((id) => !known.contains(id)).toList());
  }

  Future<Map<String, dynamic>> _bulk(
    List<String> ids, {
    Future<void> Function(List<LocalAsset> assets)? local,
    Future<void> Function(List<String> ids)? remote,
    List<String> Function(List<String> ids)? unknown,
  }) async {
    final classified = await _classify(ids);
    final result = BulkResult();
    Future<void> step(List<String> ids, Future<void> Function()? run) async {
      if (ids.isEmpty) {
        return;
      }
      if (run == null) {
        result.unsupported.addAll(ids);
        return;
      }
      try {
        await run();
        result.done.addAll(ids);
      } catch (error) {
        if (PluginHooks.isCancelled(error)) {
          result.errors.add({'ids': ids, 'cancelled': true, 'message': PluginHooks.cancelMessage(error)});
        } else {
          result.errors.add({'ids': ids, 'message': error.toString()});
        }
      }
    }

    await step([for (final asset in classified.local) asset.id], local == null ? null : () => local(classified.local));
    final remoteIds = [for (final asset in classified.remote) asset.id];
    await step(remoteIds, remote == null ? null : () => remote(remoteIds));
    final handled = unknown?.call(classified.unknown) ?? const <String>[];
    result.done.addAll(handled);
    result.unknown.addAll(classified.unknown.where((id) => !handled.contains(id)));
    return result.toJson();
  }

  Future<Map<String, dynamic>> favorite(List<String> ids, bool favorite) => _bulk(
    ids,
    local: (assets) async {
      await _deviceAlbums.setFavorite(assets, favorite);
      await _refreshLibrary();
    },
    remote: (ids) => _assets.update(ids, isFavorite: .some(favorite)),
  );

  Future<Map<String, dynamic>> setVisibility(List<String> ids, AssetVisibility visibility) =>
      _bulk(ids, remote: (ids) => _assets.update(ids, visibility: .some(visibility)));

  Future<Map<String, dynamic>> trash(List<String> ids) => _bulk(
    ids,
    local: (assets) => _assets.deleteLocal([for (final asset in assets) asset.id]),
    remote: _assets.trash,
  );

  Future<Map<String, dynamic>> delete(List<String> ids, {required bool permanent}) async {
    if (!permanent) {
      return trash(ids);
    }
    final trashed = await _trashedItems(ids);
    final result = await _bulk(
      ids.where((id) => !trashed.containsKey(id)).toList(),
      local: (assets) => _assets.deleteLocal([for (final asset in assets) asset.id], trash: false),
      remote: _assets.delete,
    );
    if (trashed.isNotEmpty && await _trash.deleteForever(trashed.values.toList())) {
      (result['ids'] as List).addAll(trashed.keys);
      result['count'] = (result['ids'] as List).length;
    }
    return result;
  }

  Future<Map<String, DeviceTrashedItem>> _trashedItems(List<String> ids) async {
    if (!Platform.isAndroid) {
      return const {};
    }
    final wanted = ids.toSet();
    return {
      for (final item in await _trash.list())
        if (wanted.contains(item.id)) item.id: item,
    };
  }

  Future<Map<String, dynamic>> restore(List<String> ids) async {
    final trashed = await _trashedItems(ids);
    final restoredDevice = trashed.isNotEmpty && await _trash.restore(trashed.values.toList());
    if (restoredDevice) {
      await _refreshLibrary();
    }
    final rest = ids.where((id) => !trashed.containsKey(id)).toList();
    final result = rest.isEmpty ? BulkResult().toJson() : await _bulk(rest, remote: _assets.restoreTrash);
    if (restoredDevice) {
      (result['ids'] as List).addAll(trashed.keys);
      result['count'] = (result['ids'] as List).length;
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> trashList(Map<String, dynamic> options) async {
    if ((options.text('source') ?? 'device') == 'remote') {
      return query({'source': 'remote', 'trashed': true, 'visibility': 'any', 'limit': 5000});
    }
    return Platform.isAndroid ? [for (final item in await _trash.list()) item.toJson()] : const [];
  }

  Future<Map<String, dynamic>> emptyTrash(Map<String, dynamic> options) async {
    if ((options.text('source') ?? 'device') == 'remote') {
      final userId = _currentUserId();
      if (userId == null) {
        throw const DataHostException(401, 'No user is signed in');
      }
      return {'count': await _actions.emptyTrash(userId)};
    }
    if (!Platform.isAndroid) {
      throw const DataHostException.unsupported('The device trash is only available on Android');
    }
    final items = await _trash.list();
    final granted = items.isNotEmpty && await _trash.deleteForever(items);
    return {'count': granted ? items.length : 0};
  }

  Future<Map<String, dynamic>> setDate(List<String> ids, String dateTime) {
    final parsed = DateTime.tryParse(dateTime);
    if (parsed == null) {
      throw DataHostException.badRequest('Invalid date $dateTime');
    }
    return _bulk(
      ids,
      local: (assets) => _localMetadata(DataHooks.assetSetDate, DataEvents.assetDateChanged, assets, {
        'dateTime': dateTime,
        'dateTakenMs': parsed.millisecondsSinceEpoch,
      }),
      remote: (ids) => _assets.update(ids, dateTime: .some(dateTime)),
    );
  }

  Future<Map<String, dynamic>> setLocation(List<String> ids, double latitude, double longitude) => _bulk(
    ids,
    local: (assets) => _localMetadata(DataHooks.assetSetLocation, DataEvents.assetLocationChanged, assets, {
      'latitude': latitude,
      'longitude': longitude,
    }),
    remote: (ids) => _assets.update(ids, location: .some(LatLng(latitude, longitude))),
  );

  Future<Map<String, dynamic>> setDescription(List<String> ids, String description) => _bulk(
    ids,
    local: (assets) => _localMetadata(DataHooks.assetSetDescription, DataEvents.assetDescriptionChanged, assets, {
      'description': description,
    }),
    remote: (ids) async {
      for (final id in ids) {
        await _actions.updateDescription(id, description);
      }
    },
  );

  Future<Map<String, dynamic>> setRating(List<String> ids, int? rating) => _bulk(
    ids,
    remote: (ids) async {
      for (final id in ids) {
        await _actions.updateRating(id, rating);
      }
    },
  );

  /// Writes EXIF / MediaStore metadata of device assets through the native `updateMetadata` channel method.
  Future<void> _localMetadata(String hook, String event, List<LocalAsset> assets, Map<String, dynamic> fields) async {
    Future<void> write(List<LocalAsset> assets, Map<String, dynamic> fields) async {
      try {
        await _channel.invokeMethod<int>('updateMetadata', {
          'items': [
            for (final asset in assets) {'id': asset.id, 'video': asset.type == AssetType.video},
          ],
          ...fields,
        });
      } on MissingPluginException {
        throw const DataHostException.unsupported('Changing device photo metadata needs a newer app build');
      }
      await _refreshLibrary();
    }

    await PluginHooks.run<void>(
      hook,
      () => {
        'ids': [for (final asset in assets) asset.id],
        'source': 'local',
        ...fields,
      },
      () => write(assets, fields),
      withArgs: (args) {
        final ids = PluginArgs.strings(args['ids']).toSet();
        return write(assets.where((asset) => ids.contains(asset.id)).toList(), {
          for (final key in fields.keys) key: args[key],
        });
      },
      event: event,
    );
  }

  Future<Map<String, dynamic>> stack(List<String> ids) async {
    final userId = _currentUserId();
    if (userId == null) {
      throw const DataHostException(401, 'No user is signed in');
    }
    final classified = await _classify(ids);
    if (classified.remote.length < 2) {
      throw const DataHostException.badRequest('Stacking needs at least two server assets');
    }
    final remoteIds = [for (final id in ids) if (classified.remote.any((asset) => asset.id == id)) id];
    await _assets.stack(userId, remoteIds);
    return (BulkResult()
          ..done.addAll(remoteIds)
          ..unsupported.addAll([for (final asset in classified.local) asset.id])
          ..unknown.addAll(classified.unknown))
        .toJson();
  }

  Future<Map<String, dynamic>> unstack(List<String> ids) async {
    final classified = await _classify(ids);
    final stackIds = {
      for (final asset in classified.remote) ?asset.stackId,
      // ids that are not assets are taken as stack ids
      ...classified.unknown,
    };
    await _assets.unstack(stackIds.toList());
    return {'count': stackIds.length, 'stackIds': stackIds.toList()};
  }

  Future<Map<String, dynamic>> move(List<String> ids, String folder) {
    final cleaned = folder.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (cleaned.isEmpty) {
      throw const DataHostException.badRequest('Missing folder');
    }
    return _bulk(
      ids,
      local: (assets) async {
        await _deviceAlbums.moveTo(assets, '$cleaned/');
        await _refreshLibrary();
      },
    );
  }

  Future<Map<String, dynamic>> setPrivate(List<String> ids, bool private) async {
    if (private) {
      await _private.add(ids);
    } else {
      await _private.remove(ids);
    }
    return {'count': ids.length, 'ids': ids};
  }
}
