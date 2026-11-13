import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/tag.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_exif.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/utils/option.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

class AssetService {
  final RemoteAssetRepository _remoteRepository;
  final RemoteExifRepository _exifRepository;
  final LocalAssetRepository _localRepository;
  final AssetApiRepository _apiRepository;
  final AssetMediaRepository _mediaRepository;
  final TrashedLocalAssetRepository _trashedLocalRepository;

  const AssetService({
    required this._remoteRepository,
    required this._exifRepository,
    required this._localRepository,
    required this._apiRepository,
    required this._mediaRepository,
    required this._trashedLocalRepository,
  });

  Future<BaseAsset?> getAsset(BaseAsset asset) {
    final id = asset is LocalAsset ? asset.id : (asset as RemoteAsset).id;
    return asset is LocalAsset ? _localRepository.get(id) : _remoteRepository.get(id);
  }

  Stream<BaseAsset?> watchAsset(BaseAsset asset) {
    final id = asset is LocalAsset ? asset.id : (asset as RemoteAsset).id;
    return asset is LocalAsset ? _localRepository.watch(id) : _remoteRepository.watch(id);
  }

  Future<List<LocalAsset?>> getLocalAssetsByChecksum(String checksum) {
    return _localRepository.getByChecksum(checksum);
  }

  Future<List<RemoteAsset>> getAllRemoteAssetDebugByChecksum(String checksum) {
    return _remoteRepository.getAllDebugForChecksum(checksum);
  }

  Future<RemoteAsset?> getRemoteAsset(String id) {
    return _remoteRepository.get(id);
  }

  Future<List<RemoteAsset>> getStack(RemoteAsset asset) async {
    if (asset.stackId == null) {
      return const [];
    }

    final stack = await _remoteRepository.getStackChildren(asset);
    return [asset, ...stack];
  }

  Stream<ExifInfo?> watchExif(BaseAsset asset) {
    if (!asset.hasRemote) {
      return Stream.value(null);
    }

    final id = asset is LocalAsset ? asset.remoteId! : (asset as RemoteAsset).id;
    return _remoteRepository.watchExif(id);
  }

  Future<List<(String, String)>> getPlaces(String userId) {
    return _remoteRepository.getPlaces(userId);
  }

  Future<(int local, int remote)> getAssetCounts() async {
    return (await _localRepository.getCount(), await _remoteRepository.getCount());
  }

  Future<int> getLocalHashedCount() {
    return _localRepository.getHashedCount();
  }

  Future<List<LocalAlbum>> getSourceAlbums(String localAssetId, {BackupSelection? backupSelection}) {
    return _localRepository.getSourceAlbums(localAssetId, backupSelection: backupSelection);
  }

  Future<void> restoreTrash(List<String> remoteIds) => PluginHooks.run<void>(
    DataHooks.assetRestore,
    () => {'ids': remoteIds, 'source': 'remote'},
    () => _restoreTrash(remoteIds),
    withArgs: (args) => _restoreTrash(PluginArgs.strings(args['ids'])),
    event: DataEvents.assetRestored,
  );

  Future<void> _restoreTrash(List<String> remoteIds) async {
    if (remoteIds.isEmpty) {
      return;
    }

    await _apiRepository.restoreTrash(remoteIds);
    await _remoteRepository.restoreTrash(remoteIds);
  }

  Future<void> stack(String userId, List<String> remoteIds) => PluginHooks.run<void>(
    DataHooks.assetStack,
    () => {'ids': remoteIds, 'userId': userId},
    () => _stack(userId, remoteIds),
    withArgs: (args) => _stack(userId, PluginArgs.strings(args['ids'])),
    event: DataEvents.assetStacked,
  );

  Future<void> _stack(String userId, List<String> remoteIds) async {
    if (remoteIds.isEmpty) {
      return;
    }

    final stack = await _apiRepository.stack(remoteIds);
    await _remoteRepository.stack(userId, stack);
  }

  Future<void> unstack(List<String> stackIds) => PluginHooks.run<void>(
    DataHooks.assetUnstack,
    () => {'stackIds': stackIds},
    () => _unstack(stackIds),
    withArgs: (args) => _unstack(PluginArgs.strings(args['stackIds'])),
    event: DataEvents.assetUnstacked,
  );

  Future<void> _unstack(List<String> stackIds) async {
    if (stackIds.isEmpty) {
      return;
    }

    await _remoteRepository.unStack(stackIds);
    await _apiRepository.unStack(stackIds);
  }

  /// Runs as `asset.favorite`, `asset.visibility`, `asset.setLocation` or `asset.setDate` when only that field
  /// changes, and as `asset.update` otherwise.
  Future<void> update(
    List<String> remoteIds, {
    Option<bool> isFavorite = const .none(),
    Option<AssetVisibility> visibility = const .none(),
    Option<LatLng> location = const .none(),
    Option<String> dateTime = const .none(),
  }) {
    final changes = [isFavorite.isSome, visibility.isSome, location.isSome, dateTime.isSome].where((set) => set);
    final single = changes.length == 1;
    final (hook, event) = switch (true) {
      _ when single && isFavorite.isSome => (DataHooks.assetFavorite, DataEvents.assetFavorited),
      _ when single && visibility.isSome => (DataHooks.assetVisibility, DataEvents.assetVisibilityChanged),
      _ when single && location.isSome => (DataHooks.assetSetLocation, DataEvents.assetLocationChanged),
      _ when single && dateTime.isSome => (DataHooks.assetSetDate, DataEvents.assetDateChanged),
      _ => (DataHooks.assetUpdate, DataEvents.assetUpdated),
    };
    return PluginHooks.run<void>(
      hook,
      () => {
        'ids': remoteIds,
        'source': 'remote',
        if (isFavorite case Some(:final value)) 'favorite': value,
        if (visibility case Some(:final value)) 'visibility': value.name,
        if (location case Some(:final value)) ...{'latitude': value.latitude, 'longitude': value.longitude},
        if (dateTime case Some(:final value)) 'dateTime': value,
      },
      () => _update(remoteIds, isFavorite: isFavorite, visibility: visibility, location: location, dateTime: dateTime),
      withArgs: (args) {
        final latitude = PluginArgs.real(args['latitude']);
        final longitude = PluginArgs.real(args['longitude']);
        return _update(
          PluginArgs.strings(args['ids']),
          isFavorite: .fromNullable(PluginArgs.boolean(args['favorite'])),
          visibility: .fromNullable(PluginJson.parseVisibility(args['visibility'])),
          location: latitude != null && longitude != null ? .some(LatLng(latitude, longitude)) : const .none(),
          dateTime: .fromNullable(PluginArgs.string(args['dateTime'])),
        );
      },
      event: event,
    );
  }

  Future<void> _update(
    List<String> remoteIds, {
    Option<bool> isFavorite = const .none(),
    Option<AssetVisibility> visibility = const .none(),
    Option<LatLng> location = const .none(),
    Option<String> dateTime = const .none(),
  }) async {
    if (remoteIds.isEmpty) {
      return;
    }

    final parsedDateTime = dateTime.map((dt) => DateTime.parse(dt));
    final offset = RegExp(r'[+-]\d{2}:\d{2}$').firstMatch(dateTime.unwrapOrNull ?? '')?.group(0);

    await _apiRepository.update(
      remoteIds,
      isFavorite: isFavorite,
      visibility: visibility,
      location: location,
      dateTimeOriginal: dateTime,
    );
    await _remoteRepository.updateAssets(
      remoteIds,
      isFavorite: isFavorite,
      visibility: visibility,
      createdAt: parsedDateTime,
    );
    await _exifRepository.updateExif(
      remoteIds,
      location: location,
      dateTimeOriginal: parsedDateTime,
      timeZone: .fromNullable(offset).map((o) => 'UTC$o'),
    );
  }

  Future<void> trash(List<String> remoteIds) => PluginHooks.run<void>(
    DataHooks.assetTrash,
    () => {'ids': remoteIds, 'source': 'remote'},
    () => _trash(remoteIds),
    withArgs: (args) => _trash(PluginArgs.strings(args['ids'])),
    event: DataEvents.assetTrashed,
  );

  Future<void> _trash(List<String> remoteIds) async {
    if (remoteIds.isEmpty) {
      return;
    }

    await _apiRepository.delete(remoteIds, false);
    await _remoteRepository.trash(remoteIds);
  }

  Future<void> delete(List<String> remoteIds) => PluginHooks.run<void>(
    DataHooks.assetDelete,
    () => {'ids': remoteIds, 'source': 'remote', 'permanent': true},
    () => _delete(remoteIds),
    withArgs: (args) => _delete(PluginArgs.strings(args['ids'])),
    event: DataEvents.assetDeleted,
  );

  Future<void> _delete(List<String> remoteIds) async {
    if (remoteIds.isEmpty) {
      return;
    }

    await _apiRepository.delete(remoteIds, true);
    await _remoteRepository.deleteAssets(remoteIds);
  }

  Future<void> applyEdits(String remoteId, List<AssetEdit> edits) => PluginHooks.run<void>(
    DataHooks.assetEdit,
    () => {
      'id': remoteId,
      'source': 'remote',
      'edits': [for (final edit in edits) PluginJson.edit(edit)],
    },
    () => _applyEdits(remoteId, edits),
    withArgs: (args) => _applyEdits(PluginArgs.string(args['id']) ?? remoteId, PluginJson.parseEdits(args['edits'])),
    event: DataEvents.assetEdited,
  );

  Future<void> _applyEdits(String remoteId, List<AssetEdit> edits) async {
    if (edits.isEmpty) {
      await _apiRepository.removeEdits(remoteId);
    } else {
      await _apiRepository.editAsset(remoteId, edits);
    }
  }

  /// Deletes device copies; runs as `asset.delete` with `source: "local"`. Returns how many were deleted.
  Future<int> deleteLocal(List<String> localIds, {bool trash = true}) => PluginHooks.run<int>(
    DataHooks.assetDelete,
    () => {'ids': localIds, 'source': 'local', 'trash': trash, 'permanent': !trash},
    () => _deleteLocal(localIds, trash: trash),
    withArgs: (args) =>
        _deleteLocal(PluginArgs.strings(args['ids']), trash: PluginArgs.boolean(args['trash']) ?? trash),
    encode: (count) => count,
    decode: (json) => PluginArgs.integer(json) ?? 0,
  );

  Future<int> _deleteLocal(List<String> localIds, {bool trash = true}) async {
    if (localIds.isEmpty) {
      return 0;
    }

    final deletedIds = await _mediaRepository.deleteAll(localIds, trash: trash);
    if (deletedIds.isEmpty) {
      return 0;
    }

    if (trash && CurrentPlatform.isAndroid && Store.get(StoreKey.manageLocalMediaAndroid, false)) {
      await _trashedLocalRepository.applyTrashedAssets(deletedIds);
    } else {
      await _localRepository.deleteAssets(deletedIds);
    }
    PluginHooks.emit(
      DataEvents.assetDeleted,
      () => {'ids': deletedIds, 'source': 'local', 'trash': trash, 'permanent': !trash},
    );
    return deletedIds.length;
  }

  Future<LocalAsset?> getLocalAsset(String id) {
    return _localRepository.get(id);
  }

  Future<List<Tag>> getTags(String assetId) {
    return _apiRepository.getAssetTags(assetId);
  }

  Future<void> stackEditedUpload(String localId, String remoteId, String? checksum) async {
    // a manual upload of an asset that was never hashed has no checksum yet, so we need to fetch it from the server
    final uploadedChecksum = checksum ?? await _apiRepository.getChecksum(remoteId);
    try {
      // previous_checksum still points at the version the server had before this upload
      final previousId = await _localRepository.getPreviousRemoteId(localId);
      if (previousId != null && previousId != remoteId) {
        await _apiRepository.stack([remoteId, previousId]);
      }
    } finally {
      // the upload went through even when the stack call did not, so this version is the new base
      await _localRepository.updatePreviousChecksum(localId, uploadedChecksum);
    }
  }
}
