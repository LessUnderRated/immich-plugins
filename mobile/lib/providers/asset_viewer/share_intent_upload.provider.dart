import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_ids.dart';
import 'package:immich_mobile/models/upload/share_intent_attachment.model.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/share_intent_service.dart';
import 'package:path/path.dart' as p;

final shareIntentUploadProvider = StateNotifierProvider<ShareIntentUploadStateNotifier, List<ShareIntentAttachment>>(
  (ref) => ShareIntentUploadStateNotifier(
    ref.watch(appRouterProvider),
    ref.read(foregroundUploadServiceProvider),
    ref.read(shareIntentServiceProvider),
  ),
);

class ShareIntentUploadStateNotifier extends StateNotifier<List<ShareIntentAttachment>> {
  final AppRouter router;
  final ForegroundUploadService _foregroundUploadService;
  final ShareIntentService _shareIntentService;

  ShareIntentUploadStateNotifier(this.router, this._foregroundUploadService, this._shareIntentService) : super([]);

  void init() {
    _shareIntentService.onSharedMedia = onSharedMedia;
    _shareIntentService.init();
  }

  /// Files shared to the app. Runs the `share.intent` hook (a plugin may cancel, reduce or replace the files, or
  /// handle them `instead` so the share page does not open) and emits `shareIntent.received`.
  void onSharedMedia(List<ShareIntentAttachment> attachments) {
    if (!ShellHookRunner.has(ShellHooks.shareIntent)) {
      _openSharePage(attachments);
      return;
    }
    unawaited(
      ShellHookRunner.guard<bool>(
        ShellHooks.shareIntent,
        {'files': _filesJson(attachments)},
        (args) async {
          _openSharePage(_attachmentsFrom(args['files'], attachments));
          return true;
        },
        encode: (opened) => opened,
        decode: (_) => false,
      ),
    );
  }

  void _openSharePage(List<ShareIntentAttachment> attachments) {
    ShellHookRunner.emit(ShellEvents.shareIntentReceived, () => {'files': _filesJson(attachments)});
    router.removeWhere((route) => route.name == "ShareIntentRoute");
    clearAttachments();
    addAttachments(attachments);
    unawaited(router.push(ShareIntentRoute(attachments: attachments)));
  }

  static List<Map<String, dynamic>> _filesJson(List<ShareIntentAttachment> attachments) => [
    for (final attachment in attachments)
      {'path': attachment.path, 'type': attachment.type.name, 'size': attachment.fileLength},
  ];

  /// The attachments for the (possibly plugin-changed) `files` of the hook: known paths keep their attachment, new
  /// paths become attachments of their own.
  static List<ShareIntentAttachment> _attachmentsFrom(Object? files, List<ShareIntentAttachment> original) {
    if (files is! List) {
      return original;
    }
    final byPath = {for (final attachment in original) attachment.path: attachment};
    return [
      for (final file in files.whereType<Map>())
        if (file['path'] case final String path)
          byPath[path] ??
              ShareIntentAttachment(
                path: path,
                type: file['type'] == 'video' ? ShareIntentAttachmentType.video : ShareIntentAttachmentType.image,
                status: UploadStatus.enqueued,
                fileLength: file['size'] is num ? (file['size'] as num).toInt() : _length(path),
              ),
    ];
  }

  static int _length(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  void addAttachments(List<ShareIntentAttachment> attachments) {
    if (attachments.isEmpty) {
      return;
    }
    state = [...state, ...attachments];
  }

  void removeAttachment(ShareIntentAttachment attachment) {
    final updatedState = state.where((element) => element != attachment).toList();
    if (updatedState.length != state.length) {
      state = updatedState;
    }
  }

  void clearAttachments() {
    if (state.isEmpty) {
      return;
    }

    state = [];
  }

  Future<void> uploadAll(List<File> files) async {
    for (final file in files) {
      final fileId = p.hash(file.path).toString();
      _updateStatus(fileId, UploadStatus.running);
    }

    await _foregroundUploadService.uploadShareIntent(
      files,
      onProgress: (fileId, bytes, totalBytes) {
        final progress = totalBytes > 0 ? bytes / totalBytes : 0.0;
        _updateProgress(fileId, progress);
      },
      onSuccess: (fileId, _) {
        _updateStatus(fileId, UploadStatus.complete, progress: 1.0);
      },
      onError: (fileId, _) {
        _updateStatus(fileId, UploadStatus.failed);
      },
    );
  }

  void _updateStatus(String fileId, UploadStatus status, {double? progress}) {
    final id = int.parse(fileId);
    state = [
      for (final attachment in state)
        if (attachment.id == id)
          attachment.copyWith(status: status, uploadProgress: progress ?? attachment.uploadProgress)
        else
          attachment,
    ];
  }

  void _updateProgress(String fileId, double progress) {
    final id = int.parse(fileId);
    state = [
      for (final attachment in state)
        if (attachment.id == id) attachment.copyWith(uploadProgress: progress) else attachment,
    ];
  }
}
