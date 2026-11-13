import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/tag.model.dart';
import 'package:immich_mobile/infrastructure/repositories/device_tag.repository.dart';

final deviceTagRepositoryProvider = Provider<DeviceTagRepository>((ref) {
  ref.keepAlive();
  return DeviceTagRepository();
});

final _deviceTagChangesProvider = StreamProvider<void>((ref) => ref.watch(deviceTagRepositoryProvider).changes);

/// Every device tag (after `tag.query`).
final deviceTagsProvider = FutureProvider<List<Tag>>((ref) {
  ref.watch(_deviceTagChangesProvider);
  return ref.watch(deviceTagRepositoryProvider).all();
});

/// The device tags of one asset.
final deviceAssetTagsProvider = FutureProvider.family<List<Tag>, String>((ref, assetId) {
  ref.watch(_deviceTagChangesProvider);
  return ref.watch(deviceTagRepositoryProvider).forAsset(assetId);
});
