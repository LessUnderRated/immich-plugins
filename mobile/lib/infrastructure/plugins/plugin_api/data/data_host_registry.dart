import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/albums_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/assets_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/db_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/downloader.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/downloads_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/files_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/media_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/net_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/people_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/settings_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/sync_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/tags_api.dart';
import 'package:immich_mobile/infrastructure/repositories/device_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/app_album.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/downloads_rule.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/device_tag.provider.dart';
import 'package:immich_mobile/providers/infrastructure/device_trash.provider.dart';
import 'package:immich_mobile/providers/infrastructure/media_writer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/repositories/download.repository.dart';
import 'package:immich_mobile/services/action.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';

/// Everything the data area contributes to the plugin kernel, built from the app's providers.
///
/// Phase B wiring (`data_plugin_api.dart`): register every entry of [functions] with `kernel.registerHost` (mapping
/// [DataHostException] to the kernel's failed-call result and passing [docs]), call [watcher] `refresh()` whenever
/// plugins or their event subscriptions change, and cancel [downloader] downloads of a plugin that is disabled or
/// removed. Hook and event ids for introspection are [DataHooks.all] and [DataEvents.all].
class DataPluginServices {
  final List<DataHostModule> modules;
  final PluginDownloader downloader;
  final DbChangeWatcher watcher;

  DataPluginServices._(this.modules, this.downloader, this.watcher);

  /// [pluginDir] resolves a plugin's private data folder (relative plugin paths are inside it).
  factory DataPluginServices.build(Ref ref, {required PluginDirResolver pluginDir}) {
    final db = ref.read(driftProvider);
    final paths = PluginPaths(pluginDir);
    final store = StoreService.I;
    Future<void> refreshLibrary() => ref.read(backgroundSyncProvider).syncLocal();
    final downloader = PluginDownloader(paths);

    return DataPluginServices._(
      [
        DbHostApi(db, logs: ref.read(Store.logDb)),
        SettingsHostApi(store, SettingsRepository.instance),
        AssetsHostApi(
          db,
          ref.read(assetServiceProvider),
          ref.read(actionServiceProvider),
          const DeviceAlbumRepository(),
          ref.read(deviceTrashRepositoryProvider),
          ref.read(privateAlbumRepositoryProvider),
          ref.read(deviceTagRepositoryProvider),
          ref.read(appAlbumRepositoryProvider),
          ref.read(storageRepositoryProvider),
          () => store.tryGet(StoreKey.currentUser)?.id,
          refreshLibrary,
        ),
        AlbumsHostApi(
          db,
          ref.read(appAlbumRepositoryProvider),
          ref.read(remoteAlbumServiceProvider),
          const DeviceAlbumRepository(),
          () => store.tryGet(StoreKey.currentUser),
          refreshLibrary,
        ),
        TagsHostApi(ref.read(deviceTagRepositoryProvider)),
        PeopleHostApi(db, ref.read(Store.people)),
        SyncHostApi(
          ref.read(backgroundSyncProvider),
          () => ref.read(syncStatusProvider),
          ref.read(foregroundUploadServiceProvider),
          (ids) async => [
            for (final row in await (db.select(db.localAssetEntity)..where((row) => row.id.isIn(ids))).get())
              row.toDto(),
          ],
          paths,
        ),
        FilesHostApi(paths),
        downloader,
        DownloadsHostApi(db, ref.read(downloadRepositoryProvider), ref.read(downloadsOrganizerProvider)),
        MediaHostApi(ref.read(mediaWriterProvider), paths),
        NetHostApi(paths, ref.read(apiServiceProvider), store, ref.read(connectivityApiProvider)),
      ],
      downloader,
      DbChangeWatcher(db),
    );
  }

  /// Every host function of the data area by name.
  Map<String, DataHostFunction> get functions => {for (final module in modules) ...module.functions};

  /// One-line documentation of every host function.
  Map<String, String> get docs => {for (final module in modules) ...module.docs};

  Future<void> dispose() => watcher.dispose();
}
