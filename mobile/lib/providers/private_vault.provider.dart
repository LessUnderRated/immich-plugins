import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/repositories/private_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/private_files.repository.dart';
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

final privateFilesRepositoryProvider = Provider<PrivateFilesRepository>((ref) {
  ref.keepAlive();
  return PrivateFilesRepository();
});

final _privateFilesChangesProvider = StreamProvider<void>((ref) => ref.watch(privateFilesRepositoryProvider).changes);

/// Photos hidden from every app (renamed into the .nomedia private folder).
final privateFilesProvider = FutureProvider<List<PrivateFile>>((ref) {
  ref.watch(_privateFilesChangesProvider);
  return ref.watch(privateFilesRepositoryProvider).list();
});

/// Whether the app has all-files access, which full hiding needs.
final privateAccessProvider = FutureProvider<bool>((ref) => ref.watch(privateFilesRepositoryProvider).hasAccess());
