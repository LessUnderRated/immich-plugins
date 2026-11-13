import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/active_viewer.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/image_load.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/image_pipeline.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/video_overlay_model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/video_sessions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_bridge.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/api.service.dart';

/// Same shape as the kernel's `HostFunction`: called with the calling plugin's name and the JSON arguments array.
typedef ViewerHostFunction = Future<Object?> Function(String plugin, List<dynamic> args);

/// The viewer area's host functions (`viewer.*`, `video.*`, `image.load`, `image.invalidate`).
///
/// Phase B registers [functions] with the kernel (`kernel.registerHost(name, handler)`). Errors are thrown as
/// [ArgumentError] / [StateError]; the kernel turns them into `{ "success": false, "message" }`.
class ViewerHostApi {
  final Ref _ref;

  ViewerHostApi(this._ref);

  Map<String, ViewerHostFunction> get functions => {
    ViewerHostNames.viewerOpen: open,
    ViewerHostNames.viewerClose: (_, _) async => _viewer().close(),
    ViewerHostNames.viewerNext: (_, args) async => _step(1),
    ViewerHostNames.viewerPrevious: (_, args) async => _step(-1),
    ViewerHostNames.viewerCurrent: (_, _) => current(),
    ViewerHostNames.viewerShowControls: (_, args) async => _viewer().showControls(_bool(args, 0) ?? true),
    ViewerHostNames.viewerShowDetails: (_, args) async => _viewer().showDetails(_bool(args, 0) ?? true),
    ViewerHostNames.videoSessions: (_, _) async => [
      for (final session in VideoSessions.instance.sessions) session.toJson(),
    ],
    ViewerHostNames.videoSession: (_, args) async => _session(args).toJson(),
    ViewerHostNames.videoPlay: (_, args) => _session(args).controls.play(),
    ViewerHostNames.videoPause: (_, args) => _session(args).controls.pause(),
    ViewerHostNames.videoSeek: (_, args) =>
        _session(args).controls.seek(Duration(milliseconds: _num(args, 1, 'positionMs').round())),
    ViewerHostNames.videoSetSpeed: (_, args) => _session(args).controls.setSpeed(_num(args, 1, 'speed').toDouble()),
    ViewerHostNames.videoSetVolume: (_, args) =>
        _session(args).controls.setVolume(_num(args, 1, 'volume').toDouble().clamp(0.0, 1.0)),
    ViewerHostNames.videoPosition: (_, args) async {
      final session = _session(args);
      return {
        'positionMs': session.positionMs(),
        'durationMs': session.durationMs,
        'playing': session.isPlaying,
        'speed': session.speed,
      };
    },
    ViewerHostNames.videoCapture: capture,
    ViewerHostNames.videoOverlaySet: overlaySet,
    ViewerHostNames.videoOverlayPatch: overlayPatch,
    ViewerHostNames.videoOverlayClear: overlayClear,
    ViewerHostNames.videoNativeOverlayAttach: nativeOverlayAttach,
    ViewerHostNames.videoNativeOverlayDetach: nativeOverlayDetach,
    ViewerHostNames.imageLoad: imageLoad,
    ViewerHostNames.imageInvalidate: (_, args) async {
      ImagePipeline.invalidate(assetId: args.isEmpty || args.first == null ? null : '${args.first}');
      return null;
    },
  };

  // ---- viewer ---------------------------------------------------------------------------------------------------

  /// `viewer.open([assetId])`, `viewer.open([{ "assetIds": [...], "index"?: 0 }])`.
  Future<Object?> open(String plugin, List<dynamic> args) async {
    final first = args.isEmpty ? null : args.first;
    final ids = switch (first) {
      final String id => [id],
      final Map map when map['assetIds'] is List => [for (final id in map['assetIds'] as List) '$id'],
      final Map map when map['assetId'] != null => ['${map['assetId']}'],
      _ => throw ArgumentError('viewer.open needs an asset id or { "assetIds": [...] }'),
    };
    final assets = <BaseAsset>[
      for (final id in ids)
        if (await findAsset(id) case final BaseAsset asset) asset,
    ];
    if (assets.isEmpty) {
      throw StateError('No asset found for ${ids.join(', ')}');
    }
    final index = (first is Map && first['index'] is num ? (first['index'] as num).toInt() : 0).clamp(
      0,
      assets.length - 1,
    );

    final asset = assets[index];
    final viewer = _ref.read(assetViewerProvider.notifier)..reset();
    if (asset.isVideo) {
      viewer.setControls(false);
    }
    viewer.setAsset(asset);
    unawaited(
      _ref
          .read(appRouterProvider)
          .push(
            AssetViewerRoute(
              initialIndex: index,
              timelineService: _ref.read(timelineFactoryProvider).fromAssets(assets, TimelineOrigin.deepLink),
            ),
          ),
    );
    return {'opened': assets.length};
  }

  Future<Object?> current() async {
    final handle = ActiveViewers.current;
    if (handle == null) {
      return null;
    }
    final asset = handle.currentAsset;
    return ActiveViewers.describe(handle, asset == null ? null : await ViewerPlugins.assetJson(asset));
  }

  Future<Object?> _step(int direction) async {
    final handle = _viewer();
    return {'moved': handle.jumpTo(handle.index + direction), 'index': handle.index};
  }

  ViewerHandle _viewer() => ActiveViewers.current ?? (throw StateError('No viewer is open'));

  /// A local asset by local id, else a remote asset by remote id.
  Future<BaseAsset?> findAsset(String id) async {
    final service = _ref.read(assetServiceProvider);
    return await service.getLocalAsset(id) ?? await service.getRemoteAsset(id);
  }

  // ---- video ----------------------------------------------------------------------------------------------------

  /// `video.capture([sessionId?, { "width"?, "height"?, "format"?: "rgba"|"png"|"jpeg", "quality"? }])`.
  Future<Object?> capture(String plugin, List<dynamic> args) async {
    final session = _session(args);
    final options = args.length > 1 && args[1] is Map ? args[1] as Map : const {};
    await VideoSessions.instance.ensureNative(session);
    return PluginVideoChannel.captureFrame(
      session,
      width: (options['width'] as num?)?.round(),
      height: (options['height'] as num?)?.round(),
      format: '${options['format'] ?? 'rgba'}',
      quality: (options['quality'] as num?)?.round() ?? 90,
    );
  }

  /// `video.overlay.set([target, { "layer"?, "items": [...] }])`: replaces the plugin's items in that layer.
  Future<Object?> overlaySet(String plugin, List<dynamic> args) async {
    final (target, options) = _overlayTarget(args);
    final items = _items(options['items']);
    VideoSessions.instance.overlays.set(target, _owner(plugin, options), items);
    return {'items': items.length};
  }

  /// `video.overlay.patch([target, { "layer"?, "upsert"?: [...], "remove"?: [ids] }])`.
  Future<Object?> overlayPatch(String plugin, List<dynamic> args) async {
    final (target, options) = _overlayTarget(args);
    final remove = options['remove'];
    VideoSessions.instance.overlays.patch(
      target,
      _owner(plugin, options),
      upsert: _items(options['upsert']),
      remove: remove is List ? [for (final id in remove) '$id'] : const [],
    );
    return null;
  }

  /// `video.overlay.clear([target?, { "layer"? }])`: without a layer, every layer of the plugin.
  Future<Object?> overlayClear(String plugin, List<dynamic> args) async {
    final first = args.isEmpty ? null : args.first;
    final options = args.length > 1 && args[1] is Map ? args[1] as Map : (first is Map ? first : const {});
    final target = first == null || (first is Map && first['assetId'] == null && first['sessionId'] == null)
        ? null
        : _overlayTarget(args).$1;
    final owner = options['layer'] == null ? '$plugin/*' : _owner(plugin, options);
    VideoSessions.instance.overlays.clear(owner, target: target);
    return null;
  }

  /// `video.nativeOverlay.attach([sessionId?, { "view", "id"?, "params"?, "interactive"? }])`.
  Future<Object?> nativeOverlayAttach(String plugin, List<dynamic> args) async {
    final session = _session(args);
    final options = args.length > 1 && args[1] is Map ? args[1] as Map : const {};
    final view = options['view'];
    if (view is! String) {
      throw ArgumentError('video.nativeOverlay.attach needs a "view"');
    }
    await VideoSessions.instance.ensureNative(session);
    return PluginVideoChannel.attachOverlay(
      session,
      plugin: plugin,
      view: view,
      id: '${options['id'] ?? view}',
      params: options['params'] is Map ? Map<String, dynamic>.from(options['params'] as Map) : const {},
      interactive: options['interactive'] == true,
    );
  }

  /// `video.nativeOverlay.detach([sessionId?, { "id"? }])`.
  Future<Object?> nativeOverlayDetach(String plugin, List<dynamic> args) async {
    final session = _session(args);
    final options = args.length > 1 && args[1] is Map ? args[1] as Map : const {};
    await PluginVideoChannel.detachOverlay(session, plugin: plugin, id: options['id'] as String?);
    return null;
  }

  VideoSession _session(List<dynamic> args) {
    final first = args.isEmpty ? null : args.first;
    final id = switch (first) {
      final String id when id != 'current' => id,
      final Map map when map['sessionId'] is String => map['sessionId'] as String,
      _ => null,
    };
    final session = id == null ? VideoSessions.instance.current : VideoSessions.instance.byId(id);
    return session ?? (throw StateError(id == null ? 'No video is playing' : 'No video session $id'));
  }

  (String, Map) _overlayTarget(List<dynamic> args) {
    final first = args.isEmpty ? null : args.first;
    final options = args.length > 1 && args[1] is Map ? args[1] as Map : const {};
    final target = switch (first) {
      final String id when id != 'current' => id,
      final Map map when map['assetId'] != null => VideoOverlayStore.assetTarget('${map['assetId']}'),
      final Map map when map['sessionId'] != null => '${map['sessionId']}',
      _ => _session(const []).id,
    };
    return (target, options);
  }

  static String _owner(String plugin, Map options) => '$plugin/${options['layer'] ?? 'default'}';

  static List<VideoOverlayItem> _items(Object? json) => [
    for (final item in json is List ? json : const []) ?VideoOverlayItem.fromJson(item),
  ];

  // ---- images ---------------------------------------------------------------------------------------------------

  /// `image.load([assetId, { "size"?: { "width", "height" } | maxSize, "timeMs"?, "format"?, "original"?,
  /// "processed"? }])`.
  Future<Object?> imageLoad(String plugin, List<dynamic> args) async {
    if (args.isEmpty || args.first == null) {
      throw ArgumentError('image.load needs an asset id');
    }
    final id = '${args.first}';
    final asset = await findAsset(id) ?? (throw StateError('No asset $id'));
    final options = ImageLoadOptions.fromJson(args.length > 1 ? args[1] : null);
    final result = await ViewerImageLoad.load(asset, options, videoSource: videoFrameSource);
    return {...result, 'assetId': id};
  }

  /// Where a video's frames can be read: the local file, else the server (original file).
  Future<VideoFrameSource> videoFrameSource(BaseAsset asset) async {
    final localId = asset.localId;
    if (localId != null) {
      final file = await _ref.read(storageRepositoryProvider).getFileForAsset(localId);
      if (file != null) {
        return (path: file.path, url: null, headers: const <String, String>{});
      }
    }
    final remoteId = asset.remoteId;
    if (remoteId == null) {
      throw StateError('No video file for ${asset.id}');
    }
    final endpoint = Store.get(StoreKey.serverEndpoint);
    return (
      path: null,
      url: '$endpoint/assets/$remoteId/original',
      headers: Map<String, String>.from(ApiService.getRequestHeaders()),
    );
  }

  // ---- arguments ------------------------------------------------------------------------------------------------

  static bool? _bool(List<dynamic> args, int index) {
    if (args.length <= index) {
      return null;
    }
    final value = args[index];
    return switch (value) {
      final bool b => b,
      final Map map when map['show'] is bool => map['show'] as bool,
      final Map map when map['visible'] is bool => map['visible'] as bool,
      _ => null,
    };
  }

  static num _num(List<dynamic> args, int index, String key) {
    for (final value in [if (args.length > index) args[index], if (args.isNotEmpty) args.first]) {
      if (value is num) {
        return value;
      }
      if (value is Map && value[key] is num) {
        return value[key] as num;
      }
    }
    throw ArgumentError('Missing "$key"');
  }
}
