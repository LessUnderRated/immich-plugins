import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/repositories/app_album.repository.dart';

final appAlbumRepositoryProvider = Provider<AppAlbumRepository>((ref) {
  ref.keepAlive();
  return AppAlbumRepository();
});

final _appAlbumChangesProvider = StreamProvider<void>((ref) => ref.watch(appAlbumRepositoryProvider).changes);

final appAlbumsProvider = FutureProvider<List<AppAlbum>>((ref) {
  ref.watch(_appAlbumChangesProvider);
  return ref.watch(appAlbumRepositoryProvider).list();
});

final appAlbumProvider = FutureProvider.family<AppAlbum?, String>((ref, id) async {
  final albums = await ref.watch(appAlbumsProvider.future);
  return albums.where((album) => album.id == id).firstOrNull;
});
