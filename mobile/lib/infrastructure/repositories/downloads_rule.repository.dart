import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/repositories/device_album.repository.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

class DownloadsRule {
  final bool enabled;
  final String? targetName;
  final String? targetRelativePath;

  const DownloadsRule({this.enabled = false, this.targetName, this.targetRelativePath});

  factory DownloadsRule.fromJson(Map<String, dynamic> json) => DownloadsRule(
    enabled: json['enabled'] == true,
    targetName: json['targetName'] as String?,
    targetRelativePath: json['targetRelativePath'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'targetName': targetName,
    'targetRelativePath': targetRelativePath,
  };
}

/// Moves photos and videos that land in the Download folder into a chosen folder.
class DownloadsOrganizer {
  static const _channel = MethodChannel('immich/device_media');
  static const _downloadFolders = {'download', 'downloads'};
  static const defaultTargetName = 'Videos';

  final Drift _db;
  final _log = Logger('DownloadsOrganizer');
  StreamSubscription<void>? _watch;
  Timer? _debounce;
  bool _running = false;

  DownloadsOrganizer(this._db);

  Future<File> _file() async => File(p.join((await getApplicationDocumentsDirectory()).path, 'downloads_rule.json'));

  Future<DownloadsRule> load() async {
    final file = await _file();
    if (!file.existsSync()) {
      return const DownloadsRule(enabled: true);
    }
    try {
      return DownloadsRule.fromJson(Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map));
    } catch (_) {
      return const DownloadsRule();
    }
  }

  /// Saves the rule; runs as `downloadsRule.set` and emits `downloadsRule.changed`.
  Future<void> save(DownloadsRule rule) => PluginHooks.run<void>(
    DataHooks.downloadsRuleSet,
    rule.toJson,
    () => _save(rule),
    withArgs: (args) => _save(DownloadsRule.fromJson(args)),
    event: DataEvents.downloadsRuleChanged,
  );

  Future<void> _save(DownloadsRule rule) async {
    await (await _file()).writeAsString(jsonEncode(rule.toJson()), flush: true);
  }

  /// The folder named "Videos" on the device if there is one, otherwise Movies.
  Future<({String name, String relativePath})> defaultTarget() async {
    final folders = await PhotoManager.getAssetPathList(type: RequestType.common, hasAll: false);
    for (final folder in folders) {
      if (folder.name.toLowerCase() == defaultTargetName.toLowerCase()) {
        final path = await const DeviceAlbumRepository().relativePathOf(folder.id);
        if (path != null) {
          return (name: folder.name, relativePath: path);
        }
      }
    }
    return (name: 'Movies', relativePath: 'Movies/');
  }

  Future<int> _move(List<Map<String, Object>> items, String target) async {
    if (items.isEmpty) {
      return 0;
    }
    return await _channel.invokeMethod<int>('moveToFolder', {'items': items, 'relativePath': target}) ?? 0;
  }

  void startWatching() {
    _watch ??= _db.tableUpdates(TableUpdateQuery.onTable(_db.localAssetEntity)).listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 3), () => unawaited(run()));
    });
    unawaited(run());
  }

  Future<int> run({bool force = false}) async {
    if (_running) {
      return 0;
    }
    _running = true;
    try {
      final rule = await load();
      if (!rule.enabled && !force) {
        return 0;
      }
      final target = rule.targetRelativePath ?? (await defaultTarget()).relativePath;
      final folders = await PhotoManager.getAssetPathList(type: RequestType.common, hasAll: false);
      final items = <Map<String, Object>>[];
      for (final folder in folders.where((folder) => _downloadFolders.contains(folder.name.toLowerCase()))) {
        final count = await folder.assetCountAsync;
        for (final asset in await folder.getAssetListRange(start: 0, end: count)) {
          final relative = (asset.relativePath ?? '').toLowerCase();
          if (relative.startsWith('download/') || relative.startsWith('downloads/')) {
            items.add({'id': asset.id, 'video': asset.type == AssetType.video});
          }
        }
      }
      if (items.isEmpty) {
        return 0;
      }
      // A plugin can drop items (`ids`), change the target folder or cancel the move.
      final moved = await PluginHooks.orSkip(
        PluginHooks.run<int>(
          DataHooks.downloadsOrganize,
          () => {
            'ids': [for (final item in items) item['id']],
            'relativePath': target,
            'force': force,
          },
          () => _move(items, target),
          withArgs: (args) {
            final ids = PluginArgs.strings(args['ids']).toSet();
            return _move(
              items.where((item) => ids.contains(item['id'])).toList(),
              PluginArgs.string(args['relativePath']) ?? target,
            );
          },
          encode: (moved) => moved,
          decode: (json) => PluginArgs.integer(json) ?? 0,
          event: DataEvents.downloadsOrganized,
          eventData: (args, moved) => {...args, 'moved': moved},
        ),
        0,
      );
      _log.info('Moved $moved downloaded items to $target');
      return moved;
    } catch (error, stack) {
      _log.warning('Unable to organise downloads', error, stack);
      return 0;
    } finally {
      _running = false;
    }
  }
}
