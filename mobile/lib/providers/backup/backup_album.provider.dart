import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/services/local_album.service.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_ids.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';

final backupAlbumProvider = StateNotifierProvider<BackupAlbumNotifier, List<LocalAlbum>>(
  (ref) => BackupAlbumNotifier(LocalAlbumService(ref.watch(driftProvider).localAlbumRepository)),
);

class BackupAlbumNotifier extends StateNotifier<List<LocalAlbum>> {
  BackupAlbumNotifier(this._localAlbumService) : super([]) {
    unawaited(getAll());
  }

  final LocalAlbumService _localAlbumService;

  Future<void> getAll() async {
    state = await _localAlbumService.getAll(sortBy: {SortLocalAlbumsBy.assetCount});
  }

  Future<void> selectAlbum(LocalAlbum album) =>
      _setSelection(ShellHooks.backupAlbumSelect, album, BackupSelection.selected);

  Future<void> deselectAlbum(LocalAlbum album) =>
      _setSelection(ShellHooks.backupAlbumDeselect, album, BackupSelection.none);

  Future<void> excludeAlbum(LocalAlbum album) =>
      _setSelection(ShellHooks.backupAlbumExclude, album, BackupSelection.excluded);

  /// Runs the selection change through its plugin hook (cancellable) and emits `backupAlbum.changed`.
  Future<void> _setSelection(String hookId, LocalAlbum album, BackupSelection selection) async {
    await ShellHookRunner.guard<void>(hookId, {'albumId': album.id, 'name': album.name, 'selection': selection.name}, (
      _,
    ) async {
      final updated = album.copyWith(backupSelection: selection);
      await _localAlbumService.update(updated);

      state = state.map((currentAlbum) => currentAlbum.id == updated.id ? updated : currentAlbum).toList();
    }, event: ShellEvents.backupAlbumChanged);
  }

  /// The device album with [id], or null.
  LocalAlbum? albumById(String id) {
    for (final album in state) {
      if (album.id == id) {
        return album;
      }
    }
    return null;
  }

  /// Backup selection of every device album, for the `backup.albums` host function.
  List<Map<String, dynamic>> albumsJson() => [
    for (final album in state)
      {'id': album.id, 'name': album.name, 'assetCount': album.assetCount, 'selection': album.backupSelection.name},
  ];
}
