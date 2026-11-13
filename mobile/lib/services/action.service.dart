import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';

final actionServiceProvider = Provider<ActionService>(
  (ref) => ActionService(ref.watch(assetApiRepositoryProvider), ref.watch(driftProvider).remoteAssetRepository),
);

class ActionService {
  final AssetApiRepository _assetApiRepository;
  final RemoteAssetRepository _remoteAssetRepository;

  const ActionService(this._assetApiRepository, this._remoteAssetRepository);

  Future<int> emptyTrash(String userId) => PluginHooks.run<int>(
    DataHooks.trashEmpty,
    () => {'userId': userId, 'source': 'remote'},
    () => _emptyTrash(userId),
    encode: (count) => count,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.trashEmptied,
    eventData: (args, count) => {...args, 'count': count},
  );

  Future<int> _emptyTrash(String userId) async {
    final count = await _assetApiRepository.emptyTrash();
    await _remoteAssetRepository.emptyTrash(userId);
    return count;
  }

  Future<int> restoreAllTrash(String userId) => PluginHooks.run<int>(
    DataHooks.trashRestoreAll,
    () => {'userId': userId, 'source': 'remote'},
    () => _restoreAllTrash(userId),
    encode: (count) => count,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.assetRestored,
    eventData: (args, count) => {...args, 'all': true, 'count': count},
  );

  Future<int> _restoreAllTrash(String userId) async {
    final count = await _assetApiRepository.restoreAllTrash();
    await _remoteAssetRepository.restoreAllTrash(userId);
    return count;
  }

  Future<bool> updateDescription(String assetId, String description) => PluginHooks.run<bool>(
    DataHooks.assetSetDescription,
    () => {'id': assetId, 'description': description, 'source': 'remote'},
    () => _updateDescription(assetId, description),
    withArgs: (args) =>
        _updateDescription(PluginArgs.string(args['id']) ?? assetId, PluginArgs.string(args['description']) ?? ''),
    encode: (ok) => ok,
    decode: (json) => PluginArgs.boolean(json) ?? true,
    event: DataEvents.assetDescriptionChanged,
  );

  Future<bool> _updateDescription(String assetId, String description) async {
    // update remote first, then local to ensure consistency
    await _assetApiRepository.updateDescription(assetId, description);
    await _remoteAssetRepository.updateDescription(assetId, description);

    return true;
  }

  Future<bool> updateRating(String assetId, int? rating) => PluginHooks.run<bool>(
    DataHooks.assetSetRating,
    () => {'id': assetId, 'rating': rating, 'source': 'remote'},
    () => _updateRating(assetId, rating),
    withArgs: (args) => _updateRating(PluginArgs.string(args['id']) ?? assetId, PluginArgs.integer(args['rating'])),
    encode: (ok) => ok,
    decode: (json) => PluginArgs.boolean(json) ?? true,
    event: DataEvents.assetRatingChanged,
  );

  Future<bool> _updateRating(String assetId, int? rating) async {
    // update remote first, then local to ensure consistency
    await _assetApiRepository.updateRating(assetId, rating);
    await _remoteAssetRepository.updateRating(assetId, rating);

    return true;
  }
}
