import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/device_album.repository.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/utils/error_handler.dart';

const _albums = DeviceAlbumRepository();

final _localAssetsProvider = Provider.family.autoDispose<List<LocalAsset>?, ActionSource>((ref, source) {
  final local = ref.watch(assetsActionProvider(source)).whereType<LocalAsset>().toList(growable: false);
  return local.isEmpty ? null : local;
}, dependencies: [assetsActionProvider]);

Future<void> _run(BuildContext context, WidgetRef ref, ActionSource source, Future<String> Function() operation) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final clearSelection = ref.read(clearSelectionProvider(source));
  final backgroundSync = ref.read(backgroundSyncProvider);
  try {
    final message = await operation();
    clearSelection();
    await backgroundSync.syncLocal();
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  } on PlatformException catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text(error.message ?? error.code)));
  } catch (error, stack) {
    handleError(error, stack: stack, description: 'Album operation failed');
    messenger?.showSnackBar(SnackBar(content: Text('Failed: $error')));
  }
}

Future<AlbumTarget?> pickDeviceAlbum(BuildContext context, {required String title, String? excludeAlbumId}) {
  return showModalBottomSheet<AlbumTarget>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, controller) => FutureBuilder<List<DeviceAlbum>>(
        future: _albums.albums(),
        builder: (context, snapshot) {
          final albums = (snapshot.data ?? const <DeviceAlbum>[]).where((album) => album.id != excludeAlbumId).toList();
          return ListView(
            controller: controller,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(title, style: Theme.of(context).textTheme.titleMedium),
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('New album'),
                onTap: () async {
                  final name = await _askAlbumName(context);
                  if (name != null && context.mounted) {
                    Navigator.pop(context, (name: name, relativePath: DeviceAlbumRepository.newAlbumPath(name)));
                  }
                },
              ),
              if (snapshot.connectionState != ConnectionState.done) const LinearProgressIndicator(),
              for (final album in albums)
                ListTile(
                  leading: const Icon(Icons.photo_album_outlined),
                  title: Text(album.name),
                  subtitle: Text('${album.count}'),
                  onTap: () async {
                    final relativePath = await _albums.relativePathOf(album.id);
                    if (context.mounted) {
                      Navigator.pop(context, (
                        name: album.name,
                        relativePath: relativePath ?? DeviceAlbumRepository.newAlbumPath(album.name),
                      ));
                    }
                  },
                ),
            ],
          );
        },
      ),
    ),
  );
}

Future<String?> _askAlbumName(BuildContext context) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('New album'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Album name'),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Create')),
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

String _count(int count) => count == 1 ? '1 item' : '$count items';

class AddToDeviceAlbumAction extends AssetActionBuilder {
  final String? currentAlbumId;

  const AddToDeviceAlbumAction({required super.source, this.currentAlbumId});

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
        final target = await pickDeviceAlbum(context, title: 'Add to album', excludeAlbumId: currentAlbumId);
        if (target == null || !context.mounted) {
          return;
        }
        await _run(context, ref, source, () async {
          final copied = await _albums.copyTo(assets, target.relativePath);
          return 'Added ${_count(copied)} to ${target.name}';
        });
      },
    );
  }
}

class MoveToDeviceAlbumAction extends AssetActionBuilder {
  final String? currentAlbumId;

  const MoveToDeviceAlbumAction({required super.source, this.currentAlbumId});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(_localAssetsProvider(source));
    if (assets == null) {
      return null;
    }
    return .new(
      icon: Icons.drive_file_move_outlined,
      label: 'Move to album',
      onAction: () async {
        final target = await pickDeviceAlbum(context, title: 'Move to album', excludeAlbumId: currentAlbumId);
        if (target == null || !context.mounted) {
          return;
        }
        await _run(context, ref, source, () async {
          final moved = await _albums.moveTo(assets, target.relativePath);
          return 'Moved ${_count(moved)} to ${target.name}';
        });
      },
    );
  }
}

class RemoveFromDeviceAlbumAction extends AssetActionBuilder {
  final String albumName;

  const RemoveFromDeviceAlbumAction({required super.source, required this.albumName});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(_localAssetsProvider(source));
    if (assets == null) {
      return null;
    }
    return .new(
      icon: Icons.remove_circle_outline,
      label: 'Remove',
      onAction: () async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Remove from $albumName?'),
            content: const Text(
              'Albums on this phone are folders, so the items are moved out of this album into Pictures. '
              'They stay in your gallery.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) {
          return;
        }
        await _run(context, ref, source, () async {
          final moved = await _albums.moveTo(assets, DeviceAlbumRepository.removedFolder);
          return 'Removed ${_count(moved)} from $albumName';
        });
      },
    );
  }
}

class DeviceFavoriteAction extends AssetActionBuilder {
  const DeviceFavoriteAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(_localAssetsProvider(source));
    if (assets == null) {
      return null;
    }
    final favorite = assets.any((asset) => !asset.isFavorite);
    return .new(
      icon: favorite ? Icons.favorite_border_rounded : Icons.favorite_rounded,
      label: favorite ? 'Favorite' : 'Unfavorite',
      onAction: () => _run(context, ref, source, () async {
        await _albums.setFavorite(assets, favorite);
        return favorite ? 'Added ${_count(assets.length)} to favorites' : 'Removed from favorites';
      }),
    );
  }
}
