import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/media_writer.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/server_capability.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/private_files.repository.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/action_ids.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/pages/edit/editor_session.provider.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/asset_edit_renderer.utils.dart';
import 'package:immich_mobile/utils/error_handler.dart';

const _uneditableExtensions = ['.gif', '.svg'];

/// `ref.read` of a [WidgetRef] or a [Ref], so the editor can be opened from widgets and from plugin host functions.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

final _stateProvider = Provider.family.autoDispose<RemoteAsset?, ActionSource>((ref, source) {
  final isSupported = ref.watch(serverInfoProvider.select((state) => state.serverVersion.supports(.syncAssetEditsV1)));
  if (!isSupported) {
    return null;
  }

  final assets = ref.watch(ownedAssetsActionProvider(source));
  return assets.where((asset) => asset.isEditable).singleOrNull;
}, dependencies: [ownedAssetsActionProvider]);

final _deviceStateProvider = Provider.family.autoDispose<LocalAsset?, ActionSource>((ref, source) {
  final asset = ref.watch(assetsActionProvider(source)).whereType<LocalAsset>().singleOrNull;
  if (asset == null || !isDeviceEditable(asset)) {
    return null;
  }
  return asset;
}, dependencies: [assetsActionProvider]);

final _deviceEditRevisionProvider = StateProvider<int>((ref) => 0);

final deviceEditedProvider = FutureProvider.autoDispose.family<bool, String>((ref, localId) {
  ref.watch(_deviceEditRevisionProvider);
  return ref.watch(deviceEditRepositoryProvider).hasOriginal(localId);
});

bool isDeviceEditable(LocalAsset asset) {
  final name = asset.name.toLowerCase();
  return asset.type == AssetType.image &&
      asset.playbackStyle == AssetPlaybackStyle.image &&
      !_uneditableExtensions.any(name.endsWith);
}

class EditAssetAction extends AssetActionBuilder {
  const EditAssetAction({required super.source});

  @override
  String get id => ActionIds.edit;

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final hasRemote = ref.watch(_stateProvider(source).select((asset) => asset != null));
    final hasDevice = ref.watch(_deviceStateProvider(source).select((asset) => asset != null));
    if (!hasRemote && !hasDevice) {
      return null;
    }

    return .new(
      icon: Icons.tune,
      label: context.t.edit,
      onAction: () => hasRemote ? _edit(context, ref) : _editOnDevice(context, ref),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final asset = ref.read(_stateProvider(source));
    if (asset == null) {
      return;
    }
    await _open(context, ref, asset);
  }

  Future<void> _editOnDevice(BuildContext context, WidgetRef ref) async {
    final asset = ref.read(_deviceStateProvider(source));
    if (asset == null) {
      return;
    }
    await _open(context, ref, asset);
  }

  Future<void> _open(BuildContext context, WidgetRef ref, BaseAsset asset) async {
    try {
      final route = await prepareImageEditor(ref.read, asset, isActive: () => context.mounted);
      if (route != null && context.mounted) {
        unawaited(context.pushRoute(route));
      }
    } catch (error, stack) {
      handleError(error, stack: stack, description: "Failed to open the editor for the asset");
    }
  }
}

/// Whether [asset] can be opened in the image editor (server edits for owned remote images, device edits for local
/// images).
bool canEditImage(ProviderReader read, BaseAsset asset) => switch (asset) {
  RemoteAsset() =>
    read(serverInfoProvider).serverVersion.supports(.syncAssetEditsV1) &&
        asset.ownerId == read(authUserProvider).id &&
        asset.isEditable,
  LocalAsset() => isDeviceEditable(asset),
};

/// Loads [asset] into the editor (edit state and session) and returns the route that shows it, or null when the asset
/// cannot be edited or [isActive] turned false while loading.
Future<EditImageRoute?> prepareImageEditor(ProviderReader read, BaseAsset asset, {bool Function()? isActive}) async {
  bool active() => isActive?.call() ?? true;
  if (!canEditImage(read, asset)) {
    return null;
  }

  switch (asset) {
    case RemoteAsset():
      // TODO(shenlong): Move all EXIF and Apply Edits logic onto the Route
      final repository = read(driftProvider).remoteAssetRepository;
      final (edits, exif) = await (repository.getAssetEdits(asset.id), repository.watchExif(asset.id).first).wait;
      if (exif == null || !active()) {
        return null;
      }

      final provider = getFullImageProvider(asset, edited: false);
      read(editorStateProvider.notifier).init(edits, exif);
      read(editorSessionProvider.notifier).start(asset: asset, provider: provider);
      return EditImageRoute(
        image: Image(image: provider),
        applyEdits: (newEdits) => applyEdits(read, asset.id, newEdits),
      );

    case LocalAsset():
      final repository = read(deviceEditRepositoryProvider);
      final bytes = await repository.readEditBase(asset.id);
      if (bytes == null || !active()) {
        return null;
      }

      final decoded = await decodeEditableImage(bytes);
      final exif = ExifInfo(width: decoded.width, height: decoded.height);
      decoded.dispose();
      if (!active()) {
        return null;
      }

      final existing = await repository.getEdits(asset.id);
      if (!active()) {
        return null;
      }
      read(editorStateProvider.notifier).init(existing, exif);
      read(editorSessionProvider.notifier).start(asset: asset, bytes: bytes, width: exif.width, height: exif.height);
      return EditImageRoute(
        image: Image.memory(bytes),
        applyEdits: (edits) => applyDeviceEdits(read, asset, edits),
        saveAsCopy: (edits) => saveDeviceEditsAsCopy(read, asset, edits),
      );
  }
}

@visibleForTesting
Future<void> applyEdits(ProviderReader read, String remoteId, List<AssetEdit> edits) async {
  final websocket = read(websocketProvider.notifier);

  bool isCurrentId(dynamic data) => data is Map && (data['asset'] as Map?)?['id'] == remoteId;
  await read(assetServiceProvider).applyEdits(remoteId, edits);
  await Future.any([
    websocket.waitForEvent('AssetEditReadyV1', isCurrentId, const .new(seconds: 10)),
    websocket.waitForEvent('AssetEditReadyV2', isCurrentId, const .new(seconds: 10)),
  ]).catchError((_) {});
}

Future<void> applyDeviceEdits(ProviderReader read, LocalAsset asset, List<AssetEdit> edits) async {
  final backgroundSync = read(backgroundSyncProvider);
  await read(deviceEditRepositoryProvider).applyEdits(asset, edits);
  read(_deviceEditRevisionProvider.notifier).state++;
  if (isPrivateAssetId(asset.id)) {
    read(privateFilesRepositoryProvider).notifyChanged();
  } else {
    unawaited(backgroundSync.syncLocal());
  }
}

Future<void> saveDeviceEditsAsCopy(ProviderReader read, LocalAsset asset, List<AssetEdit> edits) async {
  final backgroundSync = read(backgroundSyncProvider);
  final copy = await read(deviceEditRepositoryProvider).saveEditsAsCopy(asset, edits);
  if (!isPrivateAssetId(asset.id)) {
    MediaWriter.announceCreated(copy.id);
    await backgroundSync.syncLocal();
  }
}

final _revertStateProvider = Provider.family.autoDispose<LocalAsset?, ActionSource>((ref, source) {
  final asset = ref.watch(assetsActionProvider(source)).whereType<LocalAsset>().singleOrNull;
  if (asset == null || asset.type != AssetType.image) {
    return null;
  }
  return ref.watch(deviceEditedProvider(asset.id)).valueOrNull == true ? asset : null;
}, dependencies: [assetsActionProvider]);

class RevertEditsAction extends AssetActionBuilder {
  const RevertEditsAction({required super.source});

  @override
  String get id => ActionIds.revertEdits;

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(_revertStateProvider(source));
    if (asset == null) {
      return null;
    }
    return .new(icon: Icons.restore, label: 'Revert to original', onAction: () => _revert(context, ref, asset));
  }

  Future<void> _revert(BuildContext context, WidgetRef ref, LocalAsset asset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: const Text('Revert to original?'),
        content: const Text('All edits to this photo are undone, including edits made by plugins.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Revert')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    final backgroundSync = ref.read(backgroundSyncProvider);
    try {
      await ref.read(deviceEditRepositoryProvider).removeEdits(asset);
      ref.read(_deviceEditRevisionProvider.notifier).state++;
      if (isPrivateAssetId(asset.id)) {
        ref.read(privateFilesRepositoryProvider).notifyChanged();
      } else {
        unawaited(backgroundSync.syncLocal());
      }
      messenger?.showSnackBar(const SnackBar(content: Text('Reverted to the original')));
    } catch (error, stack) {
      handleError(error, stack: stack, description: 'Failed to revert the edits');
    }
  }
}
