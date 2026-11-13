import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/models/download/livephotos_medatada.model.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';

final downloadRepositoryProvider = Provider((ref) => DownloadRepository());

class DownloadRepository {
  static final _downloader = FileDownloader();
  static final _dummyTask = DownloadTask(
    taskId: 'dummy',
    url: '',
    filename: 'dummy',
    group: '',
    updates: Updates.statusAndProgress,
  );
  static final _dummyMetadata = {'part': LivePhotosPart.image.index, 'id': ''};

  void Function(TaskStatusUpdate)? onImageDownloadStatus;

  void Function(TaskStatusUpdate)? onVideoDownloadStatus;

  void Function(TaskStatusUpdate)? onLivePhotoDownloadStatus;

  void Function(TaskProgressUpdate)? onTaskProgress;

  // #29900: `taskStatusCallback` is called before the DB has been updated, causing a race between the two Live Photo tasks
  // This callback instead listens directly to DB updates
  void Function(TaskRecord)? onLivePhotoRecordComplete;

  DownloadRepository() {
    _downloader.registerCallbacks(
      group: kDownloadGroupImage,
      taskStatusCallback: (update) => onImageDownloadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );

    _downloader.registerCallbacks(
      group: kDownloadGroupVideo,
      taskStatusCallback: (update) => onVideoDownloadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );

    _downloader.registerCallbacks(
      group: kDownloadGroupLivePhoto,
      taskStatusCallback: (update) => onLivePhotoDownloadStatus?.call(update),
      taskProgressCallback: (update) => onTaskProgress?.call(update),
    );

    _downloader.database.updates
        .where((record) => record.group == kDownloadGroupLivePhoto && record.status == TaskStatus.complete)
        .listen((record) => onLivePhotoRecordComplete?.call(record));
  }

  Future<List<TaskRecord>> getLiveVideoTasks() {
    return _downloader.database.allRecordsWithStatus(TaskStatus.complete, group: kDownloadGroupLivePhoto);
  }

  Future<void> deleteRecordsWithIds(List<String> ids) {
    return _downloader.database.deleteRecordsWithIds(ids);
  }

  /// Downloads server assets into the device gallery; runs as `download.assets` (a plugin may drop assets from
  /// `ids` or cancel). Each saved file emits `asset.downloaded`.
  Future<List<bool>> downloadAllAssets(List<RemoteAsset> assets) => PluginHooks.run<List<bool>>(
    DataHooks.downloadAssets,
    () => {
      'ids': [for (final asset in assets) asset.id],
      'assets': [for (final asset in assets) PluginJson.asset(asset)],
    },
    () => _downloadAllAssets(assets),
    withArgs: (args) {
      final ids = PluginArgs.strings(args['ids']).toSet();
      return _downloadAllAssets(assets.where((asset) => ids.contains(asset.id)).toList());
    },
    encode: (queued) => queued,
    decode: (json) => [for (final value in json is List ? json : const []) value == true],
  );

  Future<List<bool>> _downloadAllAssets(List<RemoteAsset> assets) async {
    if (assets.isEmpty) {
      return Future.value(const []);
    }

    final length = Platform.isAndroid ? assets.length : assets.length * 2;
    final tasks = List.filled(length, _dummyTask);
    int taskIndex = 0;
    final headers = ApiService.getRequestHeaders();
    for (final asset in assets) {
      if (!asset.isRemoteOnly) {
        continue;
      }

      final id = asset.id;
      final livePhotoVideoId = asset.livePhotoVideoId;
      final isVideo = asset.isVideo;
      final url = getOriginalUrlForRemoteId(id);

      // on iOS it cannot link the image, check if the filename has .MP extension
      // to avoid downloading the video part
      final isAndroidMotionPhoto = asset.name.contains(".MP");

      if (Platform.isAndroid || livePhotoVideoId == null || isVideo || isAndroidMotionPhoto) {
        tasks[taskIndex++] = DownloadTask(
          taskId: id,
          url: url,
          headers: headers,
          filename: asset.name,
          updates: Updates.statusAndProgress,
          group: isVideo ? kDownloadGroupVideo : kDownloadGroupImage,
        );
        continue;
      }

      _dummyMetadata['part'] = LivePhotosPart.image.index;
      _dummyMetadata['id'] = id;
      tasks[taskIndex++] = DownloadTask(
        taskId: id,
        url: url,
        headers: headers,
        filename: asset.name,
        updates: Updates.statusAndProgress,
        group: kDownloadGroupLivePhoto,
        metaData: json.encode(_dummyMetadata),
      );

      _dummyMetadata['part'] = LivePhotosPart.video.index;
      tasks[taskIndex++] = DownloadTask(
        taskId: livePhotoVideoId,
        url: getOriginalUrlForRemoteId(livePhotoVideoId),
        headers: headers,
        filename: asset.name.toUpperCase().replaceAll(RegExp(r"\.(JPG|HEIC)$"), '.MOV'),
        updates: Updates.statusAndProgress,
        group: kDownloadGroupLivePhoto,
        metaData: json.encode(_dummyMetadata),
      );
    }
    if (taskIndex == 0) {
      return Future.value(const []);
    }
    return _downloader.enqueueAll(tasks.slice(0, taskIndex));
  }
}
