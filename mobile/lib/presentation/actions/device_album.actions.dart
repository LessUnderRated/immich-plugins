import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/app_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/private_files.repository.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/action_ids.dart';
import 'package:immich_mobile/providers/app_album.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:immich_mobile/utils/error_handler.dart';

final _localAssetsProvider = Provider.family.autoDispose<List<LocalAsset>?, ActionSource>((ref, source) {
  final local = ref.watch(assetsActionProvider(source)).whereType<LocalAsset>().toList(growable: false);
  return local.isEmpty || local.any((asset) => isPrivateAssetId(asset.id)) ? null : local;
}, dependencies: [assetsActionProvider]);

Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  ActionSource source,
  Future<String> Function() operation, {
  bool resync = true,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final clearSelection = ref.read(clearSelectionProvider(source));
  final backgroundSync = ref.read(backgroundSyncProvider);
  try {
    final message = await operation();
    clearSelection();
    if (resync) {
      await backgroundSync.syncLocal();
    }
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  } on PlatformException catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text(error.message ?? error.code)));
  } catch (error, stack) {
    handleError(error, stack: stack, description: 'Album operation failed');
    messenger?.showSnackBar(SnackBar(content: Text('Failed: $error')));
  }
}

String _count(int count) => count == 1 ? '1 item' : '$count items';

Future<String?> askName(BuildContext context, {required String title, String initial = ''}) async {
  final controller = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('OK')),
      ],
    ),
  );
  controller.dispose();
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty || trimmed.contains('/') || trimmed.contains('\\')) {
    return null;
  }
  return trimmed;
}

Future<AppAlbum?> pickAppAlbum(BuildContext context, WidgetRef ref, {String? excludeAlbumId}) {
  final repository = ref.read(appAlbumRepositoryProvider);
  return showModalBottomSheet<AppAlbum>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, controller) => FutureBuilder<List<AppAlbum>>(
        future: repository.list(),
        builder: (context, snapshot) {
          final albums = (snapshot.data ?? const <AppAlbum>[]).where((album) => album.id != excludeAlbumId).toList()
            ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          return ListView(
            controller: controller,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Add to album', style: Theme.of(context).textTheme.titleMedium),
              ),
              ListTile(
                leading: const Icon(Icons.add_photo_alternate_outlined),
                title: const Text('New album'),
                onTap: () async {
                  final name = await askName(context, title: 'New album');
                  if (name == null || !context.mounted) {
                    return;
                  }
                  final album = await repository.create(name);
                  if (context.mounted) {
                    Navigator.pop(context, album);
                  }
                },
              ),
              for (final album in albums)
                ListTile(
                  leading: const Icon(Icons.photo_album_outlined),
                  title: Text(album.name),
                  subtitle: Text(_count(album.assetIds.length)),
                  onTap: () => Navigator.pop(context, album),
                ),
            ],
          );
        },
      ),
    ),
  );
}

class AddToAppAlbumAction extends AssetActionBuilder {
  final String? currentAlbumId;

  const AddToAppAlbumAction({required super.source, this.currentAlbumId});

  @override
  String get id => ActionIds.addToAppAlbum;

  @override
  Map<String, dynamic> get hookArgs => {'currentAlbumId': currentAlbumId};

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(_localAssetsProvider(source));
    if (assets == null) {
      return null;
    }
    return .new(
      icon: Icons.library_add_outlined,
      label: 'Add to album',
      onAction: () async {
        final album = await pickAppAlbum(context, ref, excludeAlbumId: currentAlbumId);
        if (album == null || !context.mounted) {
          return;
        }
        await _run(context, ref, source, resync: false, () async {
          final added = await ref.read(appAlbumRepositoryProvider).addAssets(album.id, [
            for (final asset in assets) asset.id,
          ]);
          return added == 0 ? 'Already in ${album.name}' : 'Added ${_count(added)} to ${album.name}';
        });
      },
    );
  }
}

class RemoveFromAppAlbumAction extends AssetActionBuilder {
  final String albumId;

  const RemoveFromAppAlbumAction({required super.source, required this.albumId});

  @override
  String get id => ActionIds.removeFromAppAlbum;

  @override
  Map<String, dynamic> get hookArgs => {'albumId': albumId};

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(_localAssetsProvider(source));
    if (assets == null) {
      return null;
    }
    return .new(
      icon: Icons.remove_circle_outline,
      label: 'Remove',
      onAction: () => _run(context, ref, source, resync: false, () async {
        final removed = await ref.read(appAlbumRepositoryProvider).removeAssets(albumId, [
          for (final asset in assets) asset.id,
        ]);
        return 'Removed ${_count(removed)} from the album';
      }),
    );
  }
}

final _privateAssetsProvider = Provider.family.autoDispose<List<LocalAsset>?, ActionSource>((ref, source) {
  final local = ref.watch(assetsActionProvider(source)).whereType<LocalAsset>().toList(growable: false);
  return local.isNotEmpty && local.every((asset) => isPrivateAssetId(asset.id)) ? local : null;
}, dependencies: [assetsActionProvider]);

class DeviceFavoriteAction extends AssetActionBuilder {
  const DeviceFavoriteAction({required super.source});

  ActionItem _privateFavorite(BuildContext context, WidgetRef ref, List<LocalAsset> assets) {
    final favorite = assets.any((asset) => !asset.isFavorite);
    return .new(
      icon: favorite ? Icons.favorite_border_rounded : Icons.favorite_rounded,
      label: favorite ? 'Favorite' : 'Unfavorite',
      onAction: () async {
        final viewer = ref.read(assetViewerProvider.notifier);
        final current = ref.read(assetViewerProvider).currentAsset;
        await _run(context, ref, source, resync: false, () async {
          await ref.read(privateFilesRepositoryProvider).setFavorite([
            for (final asset in assets) privateFilePathOf(asset.id),
          ], favorite);
          return favorite ? 'Added ${_count(assets.length)} to favorites' : 'Removed from favorites';
        });
        if (source == ActionSource.viewer && current is LocalAsset && assets.any((asset) => asset.id == current.id)) {
          viewer.setAsset(current.copyWith(isFavorite: favorite));
        }
      },
    );
  }

  @override
  String get id => ActionIds.deviceFavorite;

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final privateAssets = ref.watch(_privateAssetsProvider(source));
    if (privateAssets != null) {
      return _privateFavorite(context, ref, privateAssets);
    }
    return null;
  }
}
