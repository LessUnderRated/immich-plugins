import 'dart:async';
import 'dart:io';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/video_sessions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_bridge.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart';
import 'package:logging/logging.dart';

/// Where a video plays from: `file` (absolute path or `file://` URI), `network` (URL with headers) or `asset`.
typedef VideoSourceSpec = ({String path, String type, Map<String, String> headers});

/// The `video.source` hook: plugins may replace the file or URL a video plays from (a transcoded or censored copy,
/// another server, ...). `before` cancelling means the video is not played (the poster image stays).
abstract final class VideoSourceHook {
  static bool get isHooked => PluginHooks.has(ViewerHookIds.videoSource);

  /// Returns [source] itself when no plugin hooks `video.source`.
  static Future<VideoSourceSpec> resolve(BaseAsset asset, VideoSourceSpec source) async {
    if (!isHooked) {
      return source;
    }
    final assetJson = await ViewerPlugins.assetJson(asset);
    final result = await PluginHooks.run<Map<String, dynamic>>(
      ViewerHookIds.videoSource,
      () => {
        'asset': assetJson,
        'source': {'path': _plainPath(source), 'uri': source.path, 'type': source.type, 'headers': source.headers},
      },
      () async => {'path': source.path, 'type': source.type, 'headers': source.headers},
      encode: (value) => value,
      decode: (json) => json is Map ? Map<String, dynamic>.from(json) : const {},
    );
    final path = result['path'];
    if (path is! String || path.isEmpty) {
      return source;
    }
    final type = '${result['type'] ?? (path.startsWith('http') ? 'network' : 'file')}';
    final headers = result['headers'];
    return (
      path: type == 'file' && Platform.isAndroid && path.startsWith('/') ? File(path).uri.toString() : path,
      type: type,
      headers: headers is Map ? {for (final e in headers.entries) '${e.key}': '${e.value}'} : source.headers,
    );
  }

  static String _plainPath(VideoSourceSpec source) {
    if (source.type == 'file' && source.path.startsWith('file:')) {
      return Uri.parse(source.path).toFilePath();
    }
    return source.path;
  }
}

/// The `video.control` hook around play, pause, restart and seek from the video controls.
///
/// args: `{ "action": "play"|"pause"|"restart"|"seek", "sessionId"?, "asset", "positionMs", "fromMs"? }`.
abstract final class VideoControlHook {
  static final _log = Logger('VideoControlHook');

  static bool get isHooked => PluginHooks.has(ViewerHookIds.videoControl);

  /// Runs [builtin] for [action]; synchronous without a plugin on `video.control`. When a plugin cancels or replaces
  /// it, [onSkipped] runs (the seek bar uses it to jump back to where the drag started).
  static void dispatch(
    String action,
    BaseAsset asset, {
    VideoSession? session,
    int? positionMs,
    int? fromMs,
    required void Function() builtin,
    void Function()? onSkipped,
    void Function(String message)? onMessage,
  }) {
    if (!isHooked) {
      builtin();
      return;
    }
    unawaited(() async {
      final assetJson = await ViewerPlugins.assetJson(asset);
      var ran = false;
      try {
        await PluginHooks.run<Map<String, dynamic>?>(
          ViewerHookIds.videoControl,
          () => {
            'action': action,
            'sessionId': session?.id,
            'asset': assetJson,
            'positionMs': positionMs ?? session?.positionMs(),
            'fromMs': ?fromMs,
          },
          () async {
            ran = true;
            builtin();
            return const {'handled': 'builtin'};
          },
          encode: (value) => value,
          decode: (json) => json is Map ? Map<String, dynamic>.from(json) : null,
        );
      } catch (error, stack) {
        if (PluginHooks.isCancelled(error)) {
          final message = PluginHooks.cancelMessage(error);
          if (message != null && message.isNotEmpty) {
            onMessage?.call(message);
          }
        } else {
          _log.warning('video.control failed', error, stack);
          if (!ran) {
            ran = true;
            builtin();
          }
        }
      }
      if (!ran) {
        onSkipped?.call();
      }
    }());
  }
}
