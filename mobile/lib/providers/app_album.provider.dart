import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/repositories/app_album.repository.dart';

final appAlbumRepositoryProvider = Provider<AppAlbumRepository>((ref) {
  ref.keepAlive();
  return AppAlbumRepository();
});

final _appAlbumChangesProvider = StreamProvider<void>((ref) => ref.watch(appAlbumRepositoryProvider).changes);

/// The app albums the UI shows; plugins can filter, sort or extend them through `album.query` (`kind: "app"`).
final appAlbumsProvider = FutureProvider<List<AppAlbum>>((ref) async {
  ref.watch(_appAlbumChangesProvider);
  final albums = await ref.watch(appAlbumRepositoryProvider).list();
  PluginListCodec<AppAlbum> codec() => PluginListCodec<AppAlbum>(
    id: (album) => album.id,
    toJson: (album) => album.toPluginJson(),
    fromJson: (json) => json['id'] is String && json['name'] is String
        ? AppAlbum(
            id: json['id'] as String,
            name: json['name'] as String,
            createdAt: PluginArgs.date(json['createdAt']) ?? DateTime.now(),
            assetIds: PluginArgs.strings(json['assetIds']),
            coverAssetId: PluginArgs.string(json['coverAssetId']),
            description: PluginArgs.string(json['description']) ?? '',
          )
        : null,
  );
  return PluginHooks.filterList<AppAlbum>(DataHooks.albumQuery, () => {'kind': 'app'}, albums, codec);
});

final appAlbumProvider = FutureProvider.family<AppAlbum?, String>((ref, id) async {
  final albums = await ref.watch(appAlbumsProvider.future);
  return albums.where((album) => album.id == id).firstOrNull;
});
