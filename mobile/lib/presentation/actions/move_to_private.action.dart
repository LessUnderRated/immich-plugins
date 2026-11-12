import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/private_files.helpers.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:immich_mobile/utils/error_handler.dart';

final _stateProvider = Provider.family.autoDispose<List<LocalAsset>?, ActionSource>((ref, source) {
  final local = ref.watch(assetsActionProvider(source)).whereType<LocalAsset>().toList(growable: false);
  return local.isEmpty ? null : local;
}, dependencies: [assetsActionProvider]);

class MoveToPrivateAction extends AssetActionBuilder {
  const MoveToPrivateAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(_stateProvider(source));
    if (assets == null) {
      return null;
    }
    if (allPrivateAssets(assets)) {
      return .new(icon: Icons.lock_open_outlined, label: 'Unhide', onAction: () => _unhideFiles(context, ref, assets));
    }
    final privateIds = ref.watch(privateIdsProvider);
    final allPrivate = assets.every((asset) => privateIds.contains(asset.id));
    return .new(
      icon: allPrivate ? Icons.lock_open_outlined : Icons.lock_outline,
      label: allPrivate ? 'Unhide' : 'Private',
      onAction: () => _toggle(context, ref, assets, makePrivate: !allPrivate),
    );
  }

  Future<void> _unhideFiles(BuildContext context, WidgetRef ref, List<LocalAsset> assets) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final clearSelection = ref.read(clearSelectionProvider(source));
    try {
      final restored = await unhidePrivateAssets(ref, assets);
      clearSelection();
      messenger?.showSnackBar(SnackBar(content: Text('Moved $restored back to the gallery')));
    } catch (error, stack) {
      handleError(error, stack: stack, description: 'Failed to unhide private items');
    }
  }

  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    List<LocalAsset> assets, {
    required bool makePrivate,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final clearSelection = ref.read(clearSelectionProvider(source));
    final repository = ref.read(privateAlbumRepositoryProvider);
    final backgroundSync = ref.read(backgroundSyncProvider);
    try {
      final ids = [for (final asset in assets) asset.id];
      var changed = 0;
      if (makePrivate) {
        changed = await repository.add(ids);
        final files = ref.read(privateFilesRepositoryProvider);
        if (await files.hasAccess()) {
          changed = (await files.hide(assets)).length;
          unawaited(backgroundSync.syncLocal());
        }
      } else {
        changed = await repository.remove(ids);
      }
      clearSelection();
      final noun = changed == 1 ? 'item' : 'items';
      messenger?.showSnackBar(
        SnackBar(
          content: Text(makePrivate ? 'Moved $changed $noun to Private' : 'Moved $changed $noun back to the gallery'),
        ),
      );
    } catch (error, stack) {
      handleError(error, stack: stack, description: 'Failed to update the private album');
    }
  }
}
