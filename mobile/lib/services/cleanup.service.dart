import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';

final cleanupServiceProvider = Provider<CleanupService>((ref) {
  return CleanupService(ref.watch(driftProvider).localAssetRepository, ref.watch(assetMediaRepositoryProvider));
});

class CleanupService {
  static final int _deleteBatchSize = CurrentPlatform.isAndroid ? 2000 : 10000;

  final LocalAssetRepository _localAssetRepository;
  final AssetMediaRepository _assetMediaRepository;

  const CleanupService(this._localAssetRepository, this._assetMediaRepository);

  Future<RemovalCandidatesResult> getRemovalCandidates(
    String userId,
    DateTime cutoffDate, {
    AssetKeepType keepMediaType = AssetKeepType.none,
    bool keepFavorites = true,
    Set<String> keepAlbumIds = const {},
  }) {
    return _localAssetRepository.getRemovalCandidates(
      userId,
      cutoffDate,
      keepMediaType: keepMediaType,
      keepFavorites: keepFavorites,
      keepAlbumIds: keepAlbumIds,
    );
  }

  /// Removes device copies; runs as `asset.delete` with `source: "local"`. Returns how many were deleted.
  Future<int> deleteLocalAssets(List<String> localIds) => PluginHooks.run<int>(
    DataHooks.assetDelete,
    () => {'ids': localIds, 'source': 'local', 'trash': true, 'permanent': false},
    () => _deleteLocalAssets(localIds),
    withArgs: (args) => _deleteLocalAssets(PluginArgs.strings(args['ids'])),
    encode: (count) => count,
    decode: (json) => PluginArgs.integer(json) ?? 0,
  );

  Future<int> _deleteLocalAssets(List<String> localIds) async {
    if (localIds.isEmpty) {
      return 0;
    }

    int deletedCount = 0;

    for (int index = 0; index < localIds.length; index += _deleteBatchSize) {
      final end = index + _deleteBatchSize < localIds.length ? index + _deleteBatchSize : localIds.length;
      final batch = localIds.sublist(index, end);

      final deletedIds = await _assetMediaRepository.deleteAll(batch);
      if (deletedIds.isNotEmpty) {
        await _localAssetRepository.deleteAssets(deletedIds);
        deletedCount += deletedIds.length;
        PluginHooks.emit(
          DataEvents.assetDeleted,
          () => {'ids': deletedIds, 'source': 'local', 'trash': true, 'permanent': false},
        );
      }
    }

    return deletedCount;
  }

  /// Returns album IDs that should be kept by default (e.g., messaging app albums)
  Set<String> getDefaultKeepAlbumIds(List<(String id, String name)> albums) {
    const messagingApps = ['whatsapp', 'telegram', 'signal', 'messenger', 'viber', 'wechat', 'line'];

    final toKeep = <String>{};
    for (final (id, name) in albums) {
      final albumName = name.toLowerCase();
      if (messagingApps.any((app) => albumName.contains(app))) {
        toKeep.add(id);
      }
    }
    return toKeep;
  }
}
