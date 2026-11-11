import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
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
    return .new(icon: Icons.lock_outline, label: 'Private', onAction: () => _move(context, ref, assets));
  }

  Future<void> _move(BuildContext context, WidgetRef ref, List<LocalAsset> assets) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final clearSelection = ref.read(clearSelectionProvider(source));
    final backgroundSync = ref.read(backgroundSyncProvider);
    try {
      final moved = await ref.read(privateVaultRepositoryProvider).hide(assets);
      ref.invalidate(privateItemsProvider);
      clearSelection();
      await backgroundSync.syncLocal();
      messenger?.showSnackBar(
        SnackBar(content: Text(moved == 0 ? 'Nothing was moved' : 'Moved $moved to the private gallery')),
      );
    } catch (error, stack) {
      handleError(error, stack: stack, description: 'Failed to move items to the private gallery');
    }
  }
}
