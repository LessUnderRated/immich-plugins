import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';

class LocalAlbumService {
  final LocalAlbumRepository _repository;

  const LocalAlbumService(this._repository);

  Future<List<LocalAlbum>> getAll({Set<SortLocalAlbumsBy> sortBy = const {}}) {
    return _repository.getAll(sortBy: sortBy);
  }

  /// Device albums (folders) as the UI shows them; plugins can filter, sort or extend the list through `album.query`
  /// (`kind: "device"`).
  Stream<List<LocalAlbum>> watchAll({Set<SortLocalAlbumsBy> sortBy = const {}}) {
    return PluginHooks.filterListStream<LocalAlbum>(
      _repository.watchAll(sortBy: sortBy),
      DataHooks.albumQuery,
      () => {
        'kind': 'device',
        'sortBy': [for (final sort in sortBy) sort.name],
      },
      PluginJson.localAlbums,
    );
  }

  Future<LocalAsset?> getThumbnail(String albumId) {
    return _repository.getThumbnail(albumId);
  }

  /// Saves an album (backup selection, linked remote album); runs as `album.setBackup`.
  Future<void> update(LocalAlbum album) => PluginHooks.run<void>(
    DataHooks.albumSetBackup,
    () => {...PluginJson.localAlbum(album)},
    () => _repository.upsert(album),
    withArgs: (args) => _repository.upsert(
      album.copyWith(
        backupSelection:
            BackupSelection.values.where((value) => value.name == args['backupSelection']).firstOrNull ??
            album.backupSelection,
        linkedRemoteAlbumId: PluginArgs.string(args['linkedRemoteAlbumId']),
      ),
    ),
    event: DataEvents.albumBackupChanged,
  );

  Future<int> getCount() {
    return _repository.getCount();
  }
}
