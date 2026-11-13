import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
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
/// Plugins can filter or sort the list through `private.query` (`mode: "files"`); items are identified by `file`.
final privateFilesProvider = FutureProvider<List<PrivateFile>>((ref) async {
  ref.watch(_privateFilesChangesProvider);
  final files = await ref.watch(privateFilesRepositoryProvider).list();
  return PluginHooks.filterList<PrivateFile>(
    DataHooks.privateQuery,
    () => {'mode': 'files'},
    files,
    () => PluginListCodec<PrivateFile>(id: (file) => file.file, toJson: (file) => {'id': file.file, ...file.toJson()}),
  );
});

/// Whether the app has all-files access, which full hiding needs.
final privateAccessProvider = FutureProvider<bool>((ref) => ref.watch(privateFilesRepositoryProvider).hasAccess());
