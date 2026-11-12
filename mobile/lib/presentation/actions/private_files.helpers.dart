import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/private_files.repository.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

bool isPrivateAsset(BaseAsset asset) => asset is LocalAsset && isPrivateAssetId(asset.id);

bool allPrivateAssets(Iterable<BaseAsset> assets) => assets.isNotEmpty && assets.every(isPrivateAsset);

Future<void> sharePrivateFiles(List<PrivateFile> files) async {
  final directory = Directory(p.join((await getTemporaryDirectory()).path, 'private_share'));
  if (directory.existsSync()) {
    await directory.delete(recursive: true);
  }
  await directory.create(recursive: true);
  final shared = <XFile>[];
  for (final file in files) {
    final copy = await File(file.file).copy(p.join(directory.path, file.name));
    shared.add(XFile(copy.path, mimeType: file.mime, name: file.name));
  }
  await Share.shareXFiles(shared);
}

Future<int> unhidePrivateFiles(WidgetRef ref, List<PrivateFile> files) async {
  final restored = await ref.read(privateFilesRepositoryProvider).unhide(files);
  unawaited(Future<void>.delayed(const Duration(seconds: 1), () => ref.read(backgroundSyncProvider).syncLocal()));
  return restored;
}

Future<bool> confirmDeletePrivate(BuildContext context, int count) async =>
    await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: Text('Delete $count item${count == 1 ? '' : 's'} permanently?'),
        content: const Text('Private items are not in any trash, so this cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    ) ==
    true;

Future<void> sharePrivateAssets(WidgetRef ref, List<BaseAsset> assets) async =>
    sharePrivateFiles(await ref.read(privateFilesRepositoryProvider).forAssets(assets));

Future<int> unhidePrivateAssets(WidgetRef ref, List<BaseAsset> assets) async =>
    unhidePrivateFiles(ref, await ref.read(privateFilesRepositoryProvider).forAssets(assets));

Future<int?> deletePrivateAssets(BuildContext context, WidgetRef ref, List<BaseAsset> assets) async {
  final repository = ref.read(privateFilesRepositoryProvider);
  final files = await repository.forAssets(assets);
  if (files.isEmpty || !context.mounted || !await confirmDeletePrivate(context, files.length)) {
    return null;
  }
  await repository.delete(files);
  return files.length;
}
