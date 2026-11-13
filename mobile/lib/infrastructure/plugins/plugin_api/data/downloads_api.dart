import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';
import 'package:immich_mobile/infrastructure/repositories/downloads_rule.repository.dart';
import 'package:immich_mobile/repositories/download.repository.dart';

/// Server asset downloads into the gallery and the Download folder organizer: `downloads.assets`,
/// `downloads.rule`, `downloads.setRule`, `downloads.organize`. (Plain URL downloads are `files.download`.)
class DownloadsHostApi implements DataHostModule {
  final Drift _db;
  final DownloadRepository _downloads;
  final DownloadsOrganizer _organizer;

  const DownloadsHostApi(this._db, this._downloads, this._organizer);

  @override
  Map<String, DataHostFunction> get functions => {
    'downloads.assets': (plugin, args) => assets(HostArgs(args).ids(0, 'ids')),
    'downloads.rule': (plugin, args) async => (await _organizer.load()).toJson(),
    'downloads.setRule': (plugin, args) async {
      final current = (await _organizer.load()).toJson();
      final rule = DownloadsRule.fromJson({...current, ...HostArgs(args).map(0)});
      await _organizer.save(rule);
      return rule.toJson();
    },
    'downloads.organize': (plugin, args) async => {
      'moved': await _organizer.run(force: HostArgs(args).map(0).flag('force') ?? false),
    },
  };

  @override
  Map<String, String> get docs => const {
    'downloads.assets': '[ids] -> { queued, unknown? } (server assets into the gallery; each emits asset.downloaded)',
    'downloads.rule': '[] -> { enabled, targetName, targetRelativePath }',
    'downloads.setRule': '[{ enabled?, targetName?, targetRelativePath? }] -> rule',
    'downloads.organize': '[{ force? }] -> { moved } (moves new files out of Download now)',
  };

  Future<Map<String, dynamic>> assets(List<String> ids) async {
    final rows = await (_db.select(_db.remoteAssetEntity)..where((row) => row.id.isIn(ids))).get();
    final assets = [for (final row in rows) row.toDto()];
    final queued = await _downloads.downloadAllAssets(assets);
    final known = {for (final asset in assets) asset.id};
    return {
      'queued': queued.where((ok) => ok).length,
      'unknown': [
        for (final id in ids)
          if (!known.contains(id)) id,
      ],
    };
  }
}
