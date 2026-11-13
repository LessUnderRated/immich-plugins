import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/asset_metadata.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart' as api;
import 'package:path/path.dart' as p;

part 'background_upload.service.freezed.dart';

final backgroundUploadServiceProvider = Provider((ref) {
  final db = ref.watch(driftProvider);
  final service = BackgroundUploadService(
    ref.watch(uploadRepositoryProvider),
    ref.watch(storageRepositoryProvider),
    db.localAssetRepository,
    db.backupRepository,
    ref.watch(assetMediaRepositoryProvider),
    ref.watch(assetServiceProvider),
  );

  ref.onDispose(service.dispose);
  return service;
});

/// Metadata for upload tasks to track live photo handling
@Freezed(fromJson: false, toJson: false)
abstract class UploadTaskMetadata with _$UploadTaskMetadata {
  const UploadTaskMetadata._();

  const factory UploadTaskMetadata({
    required String localAssetId,
    required bool isLivePhotos,
    required String livePhotoVideoId,
    String? checksum,
  }) = _UploadTaskMetadata;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'localAssetId': localAssetId,
      'isLivePhotos': isLivePhotos,
      'livePhotoVideoId': livePhotoVideoId,
      'checksum': checksum,
    };
  }

  factory UploadTaskMetadata.fromMap(Map<String, dynamic> map) {
    return UploadTaskMetadata(
      localAssetId: map['localAssetId'] as String,
      isLivePhotos: map['isLivePhotos'] as bool,
      livePhotoVideoId: map['livePhotoVideoId'] as String,
      checksum: map['checksum'] as String?,
    );
  }

  factory UploadTaskMetadata.fromJson(String source) =>
      UploadTaskMetadata.fromMap(json.decode(source) as Map<String, dynamic>);

  String toJson() => json.encode(toMap());
}

/// Service for handling background uploads using iOS URLSession (background_downloader)
///
/// This service handles asynchronous background uploads that can continue
/// even when the app is suspended. Primarily used for iOS background backup.
class BackgroundUploadService {
  BackgroundUploadService(
    this._uploadRepository,
    this._storageRepository,
    this._localAssetRepository,
    this._backupRepository,
    this._assetMediaRepository,
    this._assetService,
  ) {
    _uploadRepository.onUploadStatus = _onUploadCallback;
    _uploadRepository.onTaskProgress = _onTaskProgressCallback;
  }

  final UploadRepository _uploadRepository;
  final StorageRepository _storageRepository;
  final LocalAssetRepository _localAssetRepository;
  final BackupRepository _backupRepository;
  final AssetMediaRepository _assetMediaRepository;
  final AssetService _assetService;
  final Logger _logger = Logger('BackgroundUploadService');

  final StreamController<TaskStatusUpdate> _taskStatusController = StreamController<TaskStatusUpdate>.broadcast();
  final StreamController<TaskProgressUpdate> _taskProgressController = StreamController<TaskProgressUpdate>.broadcast();

  // ignore: unused-code
  Stream<TaskStatusUpdate> get taskStatusStream => _taskStatusController.stream;
  // ignore: unused-code
  Stream<TaskProgressUpdate> get taskProgressStream => _taskProgressController.stream;

  bool shouldAbortQueuingTasks = false;

  void _onTaskProgressCallback(TaskProgressUpdate update) {
    if (!_taskProgressController.isClosed) {
      _taskProgressController.add(update);
    }
    PluginHooks.emit(
      DataEvents.uploadProgress,
      () => {
        'kind': 'background',
        'localId': update.task.taskId,
        'fileName': update.task.displayName,
        'progress': update.progress,
        'expectedFileSize': update.expectedFileSize,
      },
    );
  }

  void _onUploadCallback(TaskStatusUpdate update) {
    if (!_taskStatusController.isClosed) {
      _taskStatusController.add(update);
    }
    unawaited(_handleTaskStatusUpdate(update));
  }

  void dispose() {
    unawaited(_taskStatusController.close());
    unawaited(_taskProgressController.close());
  }

  /// Enqueue tasks to the background upload queue
  Future<List<bool>> enqueueTasks(List<UploadTask> tasks) {
    return _uploadRepository.enqueueBackgroundAll(tasks);
  }

  /// Get a list of tasks that are ENQUEUED or RUNNING
  Future<List<Task>> getActiveTasks(String group) {
    return _uploadRepository.getActiveTasks(group);
  }

  /// Start background upload using iOS URLSession
  ///
  /// Finds backup candidates, builds upload tasks, and enqueues them
  /// for background processing.
  ///
  /// Runs as `backup.start` (`mode: "background"`) and emits `backup.started`.
  Future<void> uploadBackupCandidates(String userId) => PluginHooks.run<void>(
    DataHooks.backupStart,
    () => {'mode': 'background', 'userId': userId},
    () {
      PluginHooks.emit(DataEvents.backupStarted, () => {'mode': 'background', 'userId': userId});
      return _uploadBackupCandidates(userId);
    },
  );

  Future<void> _uploadBackupCandidates(String userId) async {
    await _storageRepository.clearCache();
    shouldAbortQueuingTasks = false;

    final candidates = await _backupRepository.getCandidates(userId);
    if (candidates.isEmpty) {
      _logger.info("No new backup candidates found, finishing background upload");
      return;
    }

    _logger.info("Found ${candidates.length} backup candidates for background tasks");

    const batchSize = 100;
    final batch = candidates.take(batchSize).toList();
    final List<UploadTask> tasks = [];

    for (final asset in batch) {
      final task = await getUploadTask(asset);
      if (task != null) {
        tasks.add(task);
      }
    }

    if (tasks.isNotEmpty && !shouldAbortQueuingTasks) {
      _logger.info("Enqueuing ${tasks.length} background upload tasks");
      await enqueueTasks(tasks);
    }
  }

  /// Cancel all ongoing background uploads and reset the upload queue
  ///
  /// Returns the number of tasks left in the queue
  ///
  /// Runs as `backup.stop` (`mode: "background"`) and emits `backup.stopped`.
  Future<int> cancel() => PluginHooks.run<int>(
    DataHooks.backupStop,
    () => {'mode': 'background'},
    _cancel,
    encode: (left) => left,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.backupStopped,
    eventData: (args, left) => {...args, 'remaining': left},
  );

  Future<int> _cancel() async {
    shouldAbortQueuingTasks = true;

    await _storageRepository.clearCache();
    await _uploadRepository.reset(kBackupGroup);
    await _uploadRepository.deleteDatabaseRecords(kBackupGroup);
    await _uploadRepository.reset(kBackupLivePhotoGroup);
    await _uploadRepository.deleteDatabaseRecords(kBackupLivePhotoGroup);

    final activeTasks = await _uploadRepository.getActiveTasks(kBackupGroup);
    return activeTasks.length;
  }

  /// Resume background backup processing
  Future<void> resume() {
    return _uploadRepository.start();
  }

  Future<void> _handleTaskStatusUpdate(TaskStatusUpdate update) async {
    _emitStatus(update);
    switch (update.status) {
      case TaskStatus.complete:
        unawaited(_handleLivePhoto(update));
        unawaited(_stackEditedAsset(update));

        if (CurrentPlatform.isIOS) {
          try {
            final path = await update.task.filePath();
            await File(path).delete();
          } catch (e) {
            _logger.severe('Error deleting file path for iOS: $e');
          }
        }

      default:
        break;
    }
  }

  Future<void> _handleLivePhoto(TaskStatusUpdate update) async {
    try {
      if (update.task.metaData.isEmpty || update.task.metaData == '') {
        return;
      }

      final metadata = UploadTaskMetadata.fromJson(update.task.metaData);
      if (!metadata.isLivePhotos) {
        return;
      }

      if (update.responseBody == null || update.responseBody!.isEmpty) {
        return;
      }
      final response = jsonDecode(update.responseBody!);

      final localAsset = await _localAssetRepository.getById(metadata.localAssetId);
      if (localAsset == null) {
        return;
      }

      final uploadTask = await getLivePhotoUploadTask(localAsset, response['id'] as String);

      if (uploadTask == null) {
        return;
      }

      await enqueueTasks([uploadTask]);
    } catch (error, stackTrace) {
      dPrint(() => "Error handling live photo upload task: $error $stackTrace");
    }
  }

  Future<void> _stackEditedAsset(TaskStatusUpdate update) async {
    try {
      if (update.task.metaData.isEmpty || update.responseBody == null || update.responseBody!.isEmpty) {
        return;
      }

      final metadata = UploadTaskMetadata.fromJson(update.task.metaData);
      // The video half of a live photo carries isLivePhotos; the still that follows is the final asset
      if (metadata.isLivePhotos) {
        return;
      }

      await _assetService.stackEditedUpload(
        metadata.localAssetId,
        jsonDecode(update.responseBody!)['id'] as String,
        metadata.checksum,
      );
    } catch (error, stackTrace) {
      dPrint(() => "Error stacking edited asset upload: $error $stackTrace");
    }
  }

  void _emitStatus(TaskStatusUpdate update) {
    final info = {'kind': 'background', 'localId': update.task.taskId, 'fileName': update.task.displayName};
    switch (update.status) {
      case TaskStatus.complete:
        String? remoteId;
        try {
          remoteId = (jsonDecode(update.responseBody ?? '') as Map)['id'] as String?;
        } catch (_) {
          remoteId = null;
        }
        PluginHooks.emit(DataEvents.uploadCompleted, () => {...info, 'remoteId': remoteId});
        PluginHooks.emit(
          DataEvents.assetUploaded,
          () => {'localId': update.task.taskId, 'remoteId': remoteId, 'kind': 'background'},
        );
      case TaskStatus.failed || TaskStatus.notFound:
        PluginHooks.emit(
          DataEvents.uploadFailed,
          () => {...info, 'error': update.exception?.description, 'status': update.responseStatusCode},
        );
      case TaskStatus.running:
        PluginHooks.emit(DataEvents.uploadStarted, () => info);
      default:
        break;
    }
  }

  /// Builds the background upload task of [asset] through the `upload.asset` hook (`kind: "background"`):
  /// `before` may skip the asset (cancel) or set `path`, `fileName` and extra multipart `fields`.
  @visibleForTesting
  Future<UploadTask?> getUploadTask(LocalAsset asset, {String group = kBackupGroup, int? priority}) async {
    try {
      return await PluginHooks.run<UploadTask?>(
        DataHooks.uploadAsset,
        () => {'kind': 'background', 'localId': asset.id, 'asset': PluginJson.asset(asset), 'group': group},
        () => _getUploadTask(asset, group: group, priority: priority),
        withArgs: (args) => _getUploadTask(
          asset,
          group: group,
          priority: priority,
          path: PluginArgs.string(args['path']),
          fileName: PluginArgs.string(args['fileName']),
          fields: args['fields'] is Map
              ? {for (final entry in (args['fields'] as Map).entries) '${entry.key}': '${entry.value}'}
              : null,
        ),
        encode: (task) => task == null ? null : {'taskId': task.taskId, 'fileName': task.displayName, 'fields': task.fields},
      );
    } catch (error) {
      if (!PluginHooks.isCancelled(error)) {
        rethrow;
      }
      PluginHooks.emit(
        DataEvents.uploadSkipped,
        () => {'kind': 'background', 'localId': asset.id, 'message': PluginHooks.cancelMessage(error)},
      );
      return null;
    }
  }

  Future<UploadTask?> _getUploadTask(
    LocalAsset asset, {
    String group = kBackupGroup,
    int? priority,
    String? path,
    String? fileName,
    Map<String, String>? fields,
  }) async {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      _logger.warning("Asset entity not found for ${asset.id} - ${asset.name}");
      return null;
    }

    File? file;

    /// iOS LivePhoto has two files: a photo and a video.
    /// They are uploaded separately, with video file being upload first, then returned with the assetId
    /// The assetId is then used as a metadata for the photo file upload task.
    ///
    /// We implement two separate upload groups for this, the normal one for the video file
    /// and the higher priority group for the photo file because the video file is already uploaded.

    if (path != null) {
      file = File(path);
    } else if (entity.isLivePhoto) {
      file = await _storageRepository.getMotionFileForAsset(asset);
    } else {
      file = await _storageRepository.getFileForAsset(asset.id);
    }

    if (file == null) {
      _logger.warning("Failed to get file for asset ${asset.id} - ${asset.name}");
      return null;
    }

    final baseName = fileName ?? await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;
    // Some apps (e.g. DJI/Fusion) return names without an extension; fall back to the asset name for those.
    final extension = p.extension(file.path).isNotEmpty ? p.extension(file.path) : p.extension(asset.name);
    final originalFileName = fileName ?? p.setExtension(baseName, extension);

    final String metadata = UploadTaskMetadata(
      localAssetId: asset.id,
      isLivePhotos: entity.isLivePhoto,
      livePhotoVideoId: '',
      checksum: asset.checksum,
    ).toJson();

    final requiresWiFi = _shouldRequireWiFi(asset);

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      metadata: metadata,
      group: group,
      priority: priority,
      isFavorite: asset.isFavorite,
      requiresWiFi: requiresWiFi,
      // Visibility hidden on upload to prevent the server from running regular jobs on the live photo asset
      fields: {
        if (entity.isLivePhoto) 'visibility': api.AssetVisibility.hidden.toString(),
        ...?fields,
      },
      cloudId: entity.isLivePhoto ? null : asset.cloudId,
      adjustmentTime: entity.isLivePhoto ? null : asset.adjustmentTime?.toIso8601String(),
      latitude: entity.isLivePhoto ? null : asset.latitude?.toString(),
      longitude: entity.isLivePhoto ? null : asset.longitude?.toString(),
    );
  }

  @visibleForTesting
  Future<UploadTask?> getLivePhotoUploadTask(LocalAsset asset, String livePhotoVideoId) async {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      return null;
    }

    final file = await _storageRepository.getFileForAsset(asset.id);
    if (file == null) {
      return null;
    }

    final fields = {'livePhotoVideoId': livePhotoVideoId};

    final requiresWiFi = _shouldRequireWiFi(asset);
    final originalFileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      metadata: UploadTaskMetadata(
        localAssetId: asset.id,
        isLivePhotos: false,
        livePhotoVideoId: livePhotoVideoId,
        checksum: asset.checksum,
      ).toJson(),
      fields: fields,
      group: kBackupLivePhotoGroup,
      priority: 0, // Highest priority to get upload immediately
      isFavorite: asset.isFavorite,
      requiresWiFi: requiresWiFi,
      cloudId: asset.cloudId,
      adjustmentTime: asset.adjustmentTime?.toIso8601String(),
      latitude: asset.latitude?.toString(),
      longitude: asset.longitude?.toString(),
    );
  }

  bool _shouldRequireWiFi(LocalAsset asset) {
    final backup = SettingsRepository.instance.appConfig.backup;
    if (asset.isVideo && backup.useCellularForVideos) {
      return false;
    }
    if (!asset.isVideo && backup.useCellularForPhotos) {
      return false;
    }
    return true;
  }

  Future<UploadTask> buildUploadTask(
    File file, {
    required String group,
    required DateTime createdAt,
    required DateTime modifiedAt,
    Map<String, String>? fields,
    String? originalFileName,
    String? deviceAssetId,
    String? metadata,
    int? priority,
    bool? isFavorite,
    bool requiresWiFi = true,
    String? cloudId,
    String? adjustmentTime,
    String? latitude,
    String? longitude,
  }) async {
    final serverEndpoint = Store.get(StoreKey.serverEndpoint);
    final url = Uri.parse('$serverEndpoint/assets').toString();
    final headers = ApiService.getRequestHeaders();
    final deviceId = Store.get(StoreKey.deviceId);
    final (baseDirectory, directory, filename) = await Task.split(filePath: file.path);
    final fieldsMap = {
      'filename': originalFileName ?? filename,
      // deviceAssetId/deviceId required by server v2.7.5 and below (drop in v4.0 per #27818).
      'deviceAssetId': deviceAssetId ?? '',
      'deviceId': deviceId,
      'fileCreatedAt': createdAt.toUtc().toIso8601String(),
      'fileModifiedAt': modifiedAt.toUtc().toIso8601String(),
      'isFavorite': isFavorite?.toString() ?? 'false',
      'duration': '0',
      ...?fields,
      if (CurrentPlatform.isIOS && cloudId != null)
        'metadata': jsonEncode([
          RemoteAssetMetadataItem(
            key: RemoteAssetMetadataKey.mobileApp,
            value: RemoteAssetMobileAppMetadata(
              cloudId: cloudId,
              createdAt: createdAt.toIso8601String(),
              adjustmentTime: adjustmentTime,
              latitude: latitude,
              longitude: longitude,
            ),
          ),
        ]),
    };

    return UploadTask(
      taskId: deviceAssetId,
      displayName: originalFileName ?? filename,
      httpRequestMethod: 'POST',
      url: url,
      headers: headers,
      filename: filename,
      fields: fieldsMap,
      baseDirectory: baseDirectory,
      directory: directory,
      fileField: 'assetData',
      metaData: metadata ?? '',
      group: group,
      requiresWiFi: requiresWiFi,
      priority: priority ?? 5,
      updates: Updates.statusAndProgress,
      retries: 3,
    );
  }
}
