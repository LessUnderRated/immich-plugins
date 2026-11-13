import 'package:flutter/services.dart';

/// MediaStore writes on the `immich/device_media` channel, for the generic `media.saveImage`, `media.saveVideo` and
/// `media.replace` host functions. Errors are [PlatformException]s with code `write_denied` (the user refused or the
/// storage permission is missing), `save_failed` or `write_failed`.
class PluginMediaChannel {
  const PluginMediaChannel();

  static const channel = MethodChannel('immich/device_media');

  /// Adds [sourcePath] to the device gallery as a new item. [relativePath] like `Pictures/Immich` (must start with
  /// DCIM or Pictures for photos, DCIM or Movies for videos; otherwise it is placed under the default root).
  /// Returns `{ id, uri, displayName, relativePath, mimeType, video, path? }`; `id` is the new local asset id.
  Future<Map<String, dynamic>> saveMedia({
    required String sourcePath,
    bool video = false,
    String? displayName,
    String? mimeType,
    String? relativePath,
    int? dateTakenMs,
    String? exifSourcePath,
    bool deleteSource = false,
  }) async {
    final result = await channel.invokeMapMethod<String, dynamic>('saveMedia', {
      'sourcePath': sourcePath,
      'video': video,
      'displayName': displayName,
      'mimeType': mimeType,
      'relativePath': relativePath,
      'dateTakenMs': dateTakenMs,
      'exifSourcePath': exifSourcePath,
      'deleteSource': deleteSource,
    });
    return result ?? const {};
  }

  /// Overwrites device asset [id] with [sourcePath], asking the user for write access when needed. With
  /// [backupPath], the current file is copied there first (unless it exists and not [overwriteBackup]).
  /// [exifSourcePath] (photos) copies EXIF from that file and resets the orientation. Returns
  /// `{ id, uri, replaced, backupPath? }`.
  Future<Map<String, dynamic>> replaceMedia({
    required String id,
    required String sourcePath,
    bool video = false,
    String? backupPath,
    bool overwriteBackup = false,
    String? exifSourcePath,
    int? width,
    int? height,
  }) async {
    final result = await channel.invokeMapMethod<String, dynamic>('replaceMedia', {
      'id': id,
      'sourcePath': sourcePath,
      'video': video,
      'backupPath': backupPath,
      'overwriteBackup': overwriteBackup,
      'exifSourcePath': exifSourcePath,
      'width': width,
      'height': height,
    });
    return result ?? const {};
  }
}
