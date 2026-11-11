import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/repositories/private_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/private_vault.repository.dart';

final privateVaultRepositoryProvider = Provider((ref) => const PrivateVaultRepository());

final privateUnlockedProvider = StateProvider<bool>((ref) => false);

/// Items moved into app storage by older builds; they can still be restored.
final privateItemsProvider = FutureProvider<List<PrivateItem>>(
  (ref) => ref.watch(privateVaultRepositoryProvider).list(),
);

final privateAlbumRepositoryProvider = Provider<PrivateAlbumRepository>((ref) {
  ref.keepAlive();
  return PrivateAlbumRepository();
});

final _privateChangesProvider = StreamProvider<void>((ref) => ref.watch(privateAlbumRepositoryProvider).changes);

/// Ids of photos marked private. They are hidden from every other view.
final privateIdsProvider = Provider<Set<String>>((ref) {
  ref.watch(_privateChangesProvider);
  return ref.watch(privateAlbumRepositoryProvider).cached;
});
