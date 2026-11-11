import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/server_capability.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/asset_edit_renderer.utils.dart';
import 'package:immich_mobile/utils/error_handler.dart';

const _uneditableExtensions = ['.gif', '.svg'];

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

bool isDeviceEditable(LocalAsset asset) {
  final name = asset.name.toLowerCase();
  return asset.type == AssetType.image &&
      asset.playbackStyle == AssetPlaybackStyle.image &&
      !_uneditableExtensions.any(name.endsWith);
}

class EditAssetAction extends AssetActionBuilder {
  const EditAssetAction({required super.source});

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

    try {
      // TODO(shenlong): Move all EXIF and Apply Edits logic onto the Route
      final repository = ref.read(driftProvider).remoteAssetRepository;
      final (edits, exif) = await (repository.getAssetEdits(asset.id), repository.watchExif(asset.id).first).wait;
      if (exif == null || !context.mounted) {
        return;
      }

      ref.read(editorStateProvider.notifier).init(edits, exif);
      unawaited(
        context.pushRoute(
          EditImageRoute(
            image: Image(image: getFullImageProvider(asset, edited: false)),
            applyEdits: (newEdits) => applyEdits(ref, asset.id, newEdits),
          ),
        ),
      );
    } catch (error, stack) {
      handleError(error, stack: stack, description: "Failed to open the editor for the asset");
    }
  }

  Future<void> _editOnDevice(BuildContext context, WidgetRef ref) async {
    final asset = ref.read(_deviceStateProvider(source));
    if (asset == null) {
      return;
    }

    try {
      final repository = ref.read(deviceEditRepositoryProvider);
      final bytes = await repository.readOriginal(asset.id);
      if (bytes == null || !context.mounted) {
        return;
      }

      final decoded = await decodeEditableImage(bytes);
      final exif = ExifInfo(width: decoded.width, height: decoded.height);
      decoded.dispose();
      if (!context.mounted) {
        return;
      }

      final existing = await repository.getEdits(asset.id);
      if (!context.mounted) {
        return;
      }
      ref.read(editorStateProvider.notifier).init(existing, exif);
      unawaited(
        context.pushRoute(
          EditImageRoute(image: Image.memory(bytes), applyEdits: (edits) => applyDeviceEdits(ref, asset, edits)),
        ),
      );
    } catch (error, stack) {
      handleError(error, stack: stack, description: "Failed to open the editor for the asset");
    }
  }
}

@visibleForTesting
Future<void> applyEdits(WidgetRef ref, String remoteId, List<AssetEdit> edits) async {
  final websocket = ref.read(websocketProvider.notifier);

  bool isCurrentId(dynamic data) => data is Map && (data['asset'] as Map?)?['id'] == remoteId;
  await ref.read(assetServiceProvider).applyEdits(remoteId, edits);
  await Future.any([
    websocket.waitForEvent('AssetEditReadyV1', isCurrentId, const .new(seconds: 10)),
    websocket.waitForEvent('AssetEditReadyV2', isCurrentId, const .new(seconds: 10)),
  ]).catchError((_) {});
}

Future<void> applyDeviceEdits(WidgetRef ref, LocalAsset asset, List<AssetEdit> edits) async {
  final backgroundSync = ref.read(backgroundSyncProvider);
  await ref.read(deviceEditRepositoryProvider).applyEdits(asset, edits);
  unawaited(backgroundSync.syncLocal());
}
