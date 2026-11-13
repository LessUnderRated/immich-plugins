import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/remote_album.service.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';
import 'package:immich_mobile/infrastructure/repositories/app_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/device_album.repository.dart';

/// Album data host functions (`albums.*`) over the three kinds of albums:
///
/// * `app`: albums kept by the app (any device assets, no files moved),
/// * `device`: folders on the device (adding moves the files into the folder),
/// * `remote`: server albums.
///
/// The kind is found from the id; `albums.create` takes it as an option (default `app`). Every change runs through
/// the same hooks and events as the app's own album actions. UI-level album functions (open, pick) belong to the
/// library area.
class AlbumsHostApi implements DataHostModule {
  final Drift _db;
  final AppAlbumRepository _app;
  final RemoteAlbumService _remote;
  final DeviceAlbumRepository _device;
  final UserDto? Function() _currentUser;

  /// Rescans the device library after folder changes.
  final Future<void> Function() _refreshLibrary;

  const AlbumsHostApi(this._db, this._app, this._remote, this._device, this._currentUser, this._refreshLibrary);

  @override
  Map<String, DataHostFunction> get functions => {
    'albums.list': (plugin, args) => list(HostArgs(args).map(0)),
    'albums.get': (plugin, args) => get(HostArgs(args).text(0, 'id')),
    'albums.assets': (plugin, args) => assets(HostArgs(args).text(0, 'id'), HostArgs(args).map(1)),
    'albums.containing': (plugin, args) => containing(HostArgs(args).text(0, 'assetId')),
    'albums.create': (plugin, args) => create(HostArgs(args).text(0, 'name'), HostArgs(args).map(1)),
    'albums.rename': (plugin, args) => rename(HostArgs(args).text(0, 'id'), HostArgs(args).text(1, 'name')),
    'albums.delete': (plugin, args) => delete(HostArgs(args).text(0, 'id')),
    'albums.addAssets': (plugin, args) => addAssets(HostArgs(args).text(0, 'id'), HostArgs(args).ids(1, 'assetIds')),
    'albums.removeAssets': (plugin, args) =>
        removeAssets(HostArgs(args).text(0, 'id'), HostArgs(args).ids(1, 'assetIds')),
    'albums.setCover': (plugin, args) => setCover(HostArgs(args).text(0, 'id'), HostArgs(args).text(1, 'assetId')),
    'albums.setDescription': (plugin, args) =>
        setDescription(HostArgs(args).text(0, 'id'), HostArgs(args).optText(1) ?? ''),
    'albums.setOrder': (plugin, args) => _remoteOnly(HostArgs(args).text(0, 'id'), (id) async {
      final order = AlbumAssetOrder.values.where((order) => order.name == HostArgs(args)[1]).firstOrNull;
      if (order == null) {
        throw const DataHostException.badRequest('order must be asc or desc');
      }
      return PluginJson.remoteAlbum(await _remote.updateAlbum(id, order: order));
    }),
    'albums.share': (plugin, args) => _remoteOnly(HostArgs(args).text(0, 'id'), (id) async {
      await _remote.addUsers(albumId: id, userIds: HostArgs(args).ids(1, 'userIds'));
      return null;
    }),
    'albums.unshare': (plugin, args) => _remoteOnly(HostArgs(args).text(0, 'id'), (id) async {
      await _remote.removeUser(id, userId: HostArgs(args).text(1, 'userId'));
      return null;
    }),
  };

  @override
  Map<String, String> get docs => const {
    'albums.list': '[{ kind: "app" | "device" | "remote" | "all" }] -> [Album]',
    'albums.get': '[id] -> Album (404 when unknown)',
    'albums.assets': '[id, { limit?, offset? }] -> [AssetLite]',
    'albums.containing': '[assetId] -> [Album]',
    'albums.create': '[name, { kind = "app", assetIds?, description? }] -> Album (device: moves assetIds into '
        'Pictures/<name>/, at least one asset)',
    'albums.rename': '[id, name] -> Album (device: moves the files into a folder with the new name)',
    'albums.delete': '[id] -> null (app and remote albums; device folders are removed by deleting their assets)',
    'albums.addAssets': '[id, assetIds] -> { added } (device: moves the files into the folder)',
    'albums.removeAssets': '[id, assetIds] -> { removed } (app and remote albums)',
    'albums.setCover': '[id, assetId] -> Album (app and remote albums)',
    'albums.setDescription': '[id, text] -> Album (app and remote albums)',
    'albums.setOrder': '[id, "asc" | "desc"] -> Album (remote albums)',
    'albums.share': '[id, userIds] -> null (remote albums)',
    'albums.unshare': '[id, userId] -> null (remote albums)',
  };

  Future<String> _kind(String id) async {
    if (await _app.get(id) != null) {
      return 'app';
    }
    if (await _db.remoteAlbumRepository.get(id) != null) {
      return 'remote';
    }
    final device = await (_db.select(_db.localAlbumEntity)..where((row) => row.id.equals(id))).getSingleOrNull();
    if (device != null) {
      return 'device';
    }
    throw DataHostException.notFound('Album $id not found');
  }

  Future<Object?> _remoteOnly(String id, Future<Object?> Function(String id) run) async {
    if (await _kind(id) != 'remote') {
      throw const DataHostException.unsupported('Only server albums support this');
    }
    return run(id);
  }

  Future<List<Map<String, dynamic>>> list(Map<String, dynamic> options) async {
    final kind = options.text('kind') ?? 'all';
    return [
      if (kind == 'app' || kind == 'all')
        for (final album in await _app.list()) album.toPluginJson(),
      if (kind == 'device' || kind == 'all')
        for (final album in await _db.localAlbumRepository.getAll()) PluginJson.localAlbum(album),
      if (kind == 'remote' || kind == 'all')
        for (final album in await _db.remoteAlbumRepository.getAll()) PluginJson.remoteAlbum(album),
    ];
  }

  Future<Map<String, dynamic>> get(String id) async => switch (await _kind(id)) {
    'app' => (await _app.get(id))!.toPluginJson(),
    'remote' => PluginJson.remoteAlbum((await _db.remoteAlbumRepository.get(id))!),
    _ => PluginJson.localAlbum(
      (await _db.localAlbumRepository.getAll()).firstWhere(
        (album) => album.id == id,
        orElse: () => throw DataHostException.notFound('Album $id not found'),
      ),
    ),
  };

  Future<List<Map<String, dynamic>>> assets(String id, Map<String, dynamic> options) async {
    final List<BaseAsset> assets = switch (await _kind(id)) {
      'app' => await _localAssets((await _app.get(id))!.assetIds),
      'remote' => await _db.remoteAlbumRepository.getAssets(id),
      _ => await _db.localAlbumRepository.getAssets(id),
    };
    final offset = (options.integer('offset') ?? 0).clamp(0, assets.length);
    final limit = options.integer('limit');
    final end = limit == null ? assets.length : (offset + limit).clamp(offset, assets.length);
    return [for (final asset in assets.sublist(offset, end)) PluginJson.asset(asset)];
  }

  Future<List<LocalAsset>> _localAssets(List<String> ids) async {
    final rows = await (_db.select(_db.localAssetEntity)..where((row) => row.id.isIn(ids))).get();
    final byId = {for (final row in rows) row.id: row.toDto()};
    return [for (final id in ids) ?byId[id]];
  }

  Future<List<Map<String, dynamic>>> containing(String assetId) async {
    final deviceIds = await (_db.selectOnly(_db.localAlbumAssetEntity)
          ..addColumns([_db.localAlbumAssetEntity.albumId])
          ..where(_db.localAlbumAssetEntity.assetId.equals(assetId)))
        .map((row) => row.read(_db.localAlbumAssetEntity.albumId)!)
        .get();
    final deviceAlbums = await _db.localAlbumRepository.getAll();
    return [
      for (final album in await _app.list())
        if (album.assetIds.contains(assetId)) album.toPluginJson(),
      for (final album in deviceAlbums)
        if (deviceIds.contains(album.id)) PluginJson.localAlbum(album),
      for (final album in await _remote.getAlbumsContainingAsset(assetId)) PluginJson.remoteAlbum(album),
    ];
  }

  Future<Map<String, dynamic>> create(String name, Map<String, dynamic> options) async {
    final assetIds = options.strings('assetIds');
    final description = options.text('description');
    switch (options.text('kind') ?? 'app') {
      case 'app':
        final album = await _app.create(name, assetIds: assetIds);
        if (description != null && description.isNotEmpty) {
          await _app.update(album.id, description: description);
        }
        return (await _app.get(album.id))!.toPluginJson();
      case 'remote':
        final owner = _currentUser();
        if (owner == null) {
          throw const DataHostException(401, 'No user is signed in');
        }
        return PluginJson.remoteAlbum(
          await _remote.createAlbum(title: name, owner: owner, assetIds: assetIds, description: description),
        );
      case 'device':
        final assets = await _localAssets(assetIds);
        if (assets.isEmpty) {
          throw const DataHostException.badRequest('A device folder needs at least one device asset to move into it');
        }
        final path = DeviceAlbumRepository.newAlbumPath(name);
        final moved = await _device.moveTo(assets, path);
        await _refreshLibrary();
        return {'kind': 'device', 'name': name.trim(), 'relativePath': path, 'moved': moved};
      case final other:
        throw DataHostException.badRequest('Unknown album kind $other');
    }
  }

  Future<Map<String, dynamic>> rename(String id, String name) async {
    switch (await _kind(id)) {
      case 'app':
        await _app.rename(id, name);
        return (await _app.get(id))!.toPluginJson();
      case 'remote':
        return PluginJson.remoteAlbum(await _remote.updateAlbum(id, name: name));
      default:
        final current = await _device.relativePathOf(id);
        if (current == null) {
          throw DataHostException.notFound('Folder of album $id not found');
        }
        final parent = current.replaceAll(RegExp(r'[^/]+/$'), '');
        final target = '$parent${name.trim()}/';
        final moved = await _device.moveTo(await _db.localAlbumRepository.getAssets(id), target);
        await _refreshLibrary();
        return {'kind': 'device', 'name': name.trim(), 'relativePath': target, 'moved': moved};
    }
  }

  Future<void> delete(String id) async {
    switch (await _kind(id)) {
      case 'app':
        await _app.delete(id);
      case 'remote':
        await _remote.deleteAlbum(id);
      default:
        throw const DataHostException.unsupported(
          'Device folders disappear when they are empty; delete or move their assets instead',
        );
    }
  }

  Future<Map<String, dynamic>> addAssets(String id, List<String> assetIds) async {
    switch (await _kind(id)) {
      case 'app':
        return {'added': await _app.addAssets(id, assetIds)};
      case 'remote':
        final result = await _remote.addAssets(albumId: id, assetIds: assetIds);
        return {'added': result.added, 'failed': result.failed};
      default:
        final path = await _device.relativePathOf(id);
        if (path == null) {
          throw DataHostException.notFound('Folder of album $id not found');
        }
        final moved = await _device.moveTo(await _localAssets(assetIds), path);
        await _refreshLibrary();
        return {'added': moved};
    }
  }

  Future<Map<String, dynamic>> removeAssets(String id, List<String> assetIds) async => switch (await _kind(id)) {
    'app' => {'removed': await _app.removeAssets(id, assetIds)},
    'remote' => {'removed': await _remote.removeAssets(albumId: id, assetIds: assetIds)},
    _ => throw const DataHostException.unsupported('Move assets to another folder to take them out of a device folder'),
  };

  Future<Map<String, dynamic>> setCover(String id, String assetId) async {
    switch (await _kind(id)) {
      case 'app':
        await _app.update(id, coverAssetId: assetId);
        return (await _app.get(id))!.toPluginJson();
      case 'remote':
        return PluginJson.remoteAlbum(await _remote.updateAlbum(id, thumbnailAssetId: assetId));
      default:
        throw const DataHostException.unsupported('Device folders have no cover');
    }
  }

  Future<Map<String, dynamic>> setDescription(String id, String description) async {
    switch (await _kind(id)) {
      case 'app':
        await _app.update(id, description: description);
        return (await _app.get(id))!.toPluginJson();
      case 'remote':
        return PluginJson.remoteAlbum(await _remote.updateAlbum(id, description: description));
      default:
        throw const DataHostException.unsupported('Device folders have no description');
    }
  }
}
