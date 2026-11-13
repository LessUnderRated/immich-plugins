import 'dart:async';
import 'dart:io';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/files_api.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:path/path.dart' as p;

/// Sync control (`sync.run`, `sync.status`) and uploads to the server (`upload.assets`, `upload.files`,
/// `upload.cancel`). Backup control (`backup.*`) belongs to the shell area.
class SyncHostApi implements DataHostModule {
  final BackgroundSyncManager _sync;
  final SyncStatusState Function() _status;
  final ForegroundUploadService _uploads;
  final Future<List<LocalAsset>> Function(List<String> ids) _localAssets;
  final PluginPaths _paths;

  const SyncHostApi(this._sync, this._status, this._uploads, this._localAssets, this._paths);

  @override
  Map<String, DataHostFunction> get functions => {
    'sync.run': (plugin, args) => run(HostArgs(args).map(0)),
    'sync.status': (plugin, args) async => status(),
    'upload.assets': (plugin, args) => uploadAssets(HostArgs(args).ids(0, 'ids')),
    'upload.files': (plugin, args) async => uploadFiles([
      for (final path in HostArgs(args).ids(0, 'paths')) await _paths.resolve(plugin, path),
    ]),
    'upload.cancel': (plugin, args) async {
      _uploads.cancel();
      return null;
    },
  };

  @override
  Map<String, String> get docs => const {
    'sync.run': '[{ kind: "local" | "remote" | "hash" | "all" = "local", full? }] -> { kind, success } '
        '(waits for the sync; runs the sync.run hook)',
    'sync.status': '[] -> { local, remote, hash, cloudIds: "idle" | "syncing" | "success" | "error", error?, running }',
    'upload.assets': '[ids] -> { uploaded: [{ localId, remoteId }], failed: [{ localId, error }] } (device assets '
        'to the server; runs upload.asset per asset)',
    'upload.files': '[paths] -> { uploaded: [{ path, remoteId }], failed: [{ path, error }] }',
    'upload.cancel': '[] -> null (stops running manual uploads after the current file)',
  };

  Future<Map<String, dynamic>> run(Map<String, dynamic> options) async {
    final kind = options.text('kind') ?? 'local';
    final full = options.flag('full') ?? false;
    switch (kind) {
      case 'local':
        await _sync.syncLocal(full: full);
        return {'kind': kind, 'success': _status().localSyncStatus != SyncStatus.error};
      case 'hash':
        await _sync.hashAssets();
        return {'kind': kind, 'success': _status().hashJobStatus != SyncStatus.error};
      case 'remote':
        return {'kind': kind, 'success': await _sync.syncRemote()};
      case 'all':
        await _sync.syncLocal(full: full);
        await _sync.hashAssets();
        final remote = await _sync.syncRemote();
        return {'kind': kind, 'success': remote && _status().localSyncStatus != SyncStatus.error};
      default:
        throw DataHostException.badRequest('Unknown sync kind $kind');
    }
  }

  Map<String, dynamic> status() {
    final state = _status();
    return {
      'local': state.localSyncStatus.name,
      'remote': state.remoteSyncStatus.name,
      'hash': state.hashJobStatus.name,
      'cloudIds': state.cloudIdSyncStatus.name,
      'error': state.errorMessage,
      'running': _sync.running,
    };
  }

  Future<Map<String, dynamic>> uploadAssets(List<String> ids) async {
    final assets = await _localAssets(ids);
    final uploaded = <Map<String, dynamic>>[];
    final failed = <Map<String, dynamic>>[];
    await _uploads.uploadManual(
      assets,
      callbacks: UploadCallbacks(
        onSuccess: (localId, remoteId) => uploaded.add({'localId': localId, 'remoteId': remoteId}),
        onError: (localId, error) => failed.add({'localId': localId, 'error': error}),
        onProgress: (localId, fileName, bytes, total) => PluginHooks.emit(
          DataEvents.uploadProgress,
          () => {'kind': 'asset', 'localId': localId, 'fileName': fileName, 'bytes': bytes, 'total': total},
        ),
      ),
    );
    final known = {for (final asset in assets) asset.id};
    return {
      'uploaded': uploaded,
      'failed': [
        ...failed,
        for (final id in ids)
          if (!known.contains(id)) {'localId': id, 'error': 'not a device asset'},
      ],
    };
  }

  Future<Map<String, dynamic>> uploadFiles(List<String> paths) async {
    final files = [for (final path in paths) File(path)];
    final missing = [for (final file in files) if (!file.existsSync()) file.path];
    // uploadShareIntent identifies files by the hash of their path
    final byId = {for (final path in paths) p.hash(path).toString(): path};
    final uploaded = <Map<String, dynamic>>[];
    final failed = <Map<String, dynamic>>[for (final path in missing) {'path': path, 'error': 'file not found'}];
    final existing = files.where((file) => !missing.contains(file.path)).toList();
    await _uploads.uploadShareIntent(
      existing,
      onProgress: (fileId, bytes, total) => PluginHooks.emit(
        DataEvents.uploadProgress,
        () => {'kind': 'file', 'path': byId[fileId], 'bytes': bytes, 'total': total},
      ),
      onSuccess: (fileId, remoteId) => uploaded.add({'path': byId[fileId], 'remoteId': remoteId}),
      onError: (fileId, error) => failed.add({'path': byId[fileId], 'error': error}),
    );
    return {'uploaded': uploaded, 'failed': failed};
  }
}
