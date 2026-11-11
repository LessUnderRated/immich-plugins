import 'dart:async';

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
    final progress = ValueNotifier<(int, int)>((0, assets.length));
    final navigator = Navigator.of(context, rootNavigator: true);
    var dialogOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Moving to Private'),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: progress,
            builder: (_, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: value.$2 == 0 ? null : value.$1 / value.$2),
                const SizedBox(height: 8),
                Text('${value.$1} of ${value.$2}'),
              ],
            ),
          ),
        ),
      ).whenComplete(() => dialogOpen = false),
    );
    void closeDialog() {
      if (dialogOpen) {
        navigator.pop();
      }
    }

    try {
      final moved = await ref
          .read(privateVaultRepositoryProvider)
          .hide(assets, onProgress: (done, total) => progress.value = (done, total));
      closeDialog();
      ref.invalidate(privateItemsProvider);
      clearSelection();
      await backgroundSync.syncLocal();
      messenger?.showSnackBar(
        SnackBar(content: Text(moved == 0 ? 'Nothing was moved' : 'Moved $moved to the private gallery')),
      );
    } catch (error, stack) {
      closeDialog();
      handleError(error, stack: stack, description: 'Failed to move items to the private gallery');
    } finally {
      progress.dispose();
    }
  }
}
