import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/video_overlay_model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_bridge.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_events.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart';
import 'package:logging/logging.dart';

enum VideoSessionState { loading, ready, playing, paused, buffering, completed, error }

/// What a player lets plugins do with it. Implemented by the widget that owns the player.
abstract interface class VideoSessionControls {
  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  Future<void> setSpeed(double speed);

  Future<void> setVolume(double volume);
}

/// One playing (or loaded) video: the player of one asset on one surface. Notifies its listeners when the playback
/// state, speed or frame rect changes (not on every position update).
class VideoSession with ChangeNotifier {
  final String id;
  final BaseAsset asset;

  /// `viewer`, `slideshow` or `memory`.
  final String surface;
  final VideoSessionControls controls;
  final DateTime startedAt = DateTime.now();

  /// The platform view id of the native player (Android: `PlatformViewsController.getPlatformViewById(viewId)`).
  int? viewId;

  /// Whether the native side knows this session (`registerSession` sent).
  bool nativeRegistered = false;

  VideoSessionState state = VideoSessionState.loading;
  int durationMs = 0;
  double speed = 1;
  double volume = 1;
  bool isCurrent = false;
  bool looping = false;

  /// The decoded video size in pixels (from the player; falls back to the asset's size).
  Size? videoSize;

  /// The aspect-fit rect of the video frame inside the player, in global logical pixels (what the user sees,
  /// including zoom).
  Rect? frameRect;

  /// The size of the player box (logical pixels, before zoom) the frame is fitted into.
  Size? boxSize;

  int _positionMs = 0;
  DateTime _positionAt = DateTime.now();

  VideoSession({required this.id, required this.asset, required this.surface, required this.controls});

  String get assetId => asset.id;

  bool get isPlaying => state == VideoSessionState.playing;

  /// The last position the player reported.
  int get reportedPositionMs => _positionMs;

  /// The playback clock: the position now, extrapolated from the last report while playing.
  int positionMs([DateTime? now]) {
    if (state != VideoSessionState.playing) {
      return _positionMs;
    }
    final elapsed = (now ?? DateTime.now()).difference(_positionAt).inMicroseconds / 1000;
    final position = _positionMs + (elapsed * speed).round();
    return durationMs > 0 && position > durationMs ? durationMs : position;
  }

  void _setPosition(int positionMs) {
    _positionMs = positionMs;
    _positionAt = DateTime.now();
  }

  Map<String, dynamic> toJson({bool withAsset = true}) => {
    'sessionId': id,
    'assetId': asset.id,
    'localId': asset.localId,
    'remoteId': asset.remoteId,
    'surface': surface,
    'viewId': viewId,
    'state': state.name,
    'positionMs': positionMs(),
    'durationMs': durationMs,
    'speed': speed,
    'volume': volume,
    'isCurrent': isCurrent,
    'looping': looping,
    if (videoSize != null) 'videoSize': {'width': videoSize!.width, 'height': videoSize!.height},
    if (frameRect != null) 'frameRect': rectJson(frameRect!),
    if (withAsset) 'asset': ViewerPlugins.basicAssetJson(asset),
  };

  static Map<String, double> rectJson(Rect rect) => {
    'left': rect.left,
    'top': rect.top,
    'width': rect.width,
    'height': rect.height,
  };
}

/// Every video session of the app, the declarative overlay items, and the session events.
///
/// Sessions cost nothing extra without plugins: events are only built when a plugin listens, and the native side is
/// told about a session only when a plugin captures a frame or attaches a native overlay.
class VideoSessions extends ChangeNotifier {
  VideoSessions._();

  static final instance = VideoSessions._();

  static final _log = Logger('VideoSessions');

  final _sessions = <String, VideoSession>{};
  final _positionThrottles = <String, EventThrottle>{};
  final _frameThrottles = <String, EventThrottle>{};
  int _next = 0;

  /// Declarative overlay items per session or asset.
  final overlays = VideoOverlayStore();

  List<VideoSession> get sessions => List.unmodifiable(_sessions.values);

  VideoSession? byId(String id) => _sessions[id];

  /// The session of the current page of the viewer (or slideshow / memory), else the most recent one.
  VideoSession? get current {
    VideoSession? latest;
    for (final session in _sessions.values) {
      if (session.isCurrent) {
        return session;
      }
      latest = session;
    }
    return latest;
  }

  /// Sessions of [assetId] (local or remote id).
  Iterable<VideoSession> ofAsset(String assetId) =>
      _sessions.values.where((s) => s.asset.id == assetId || s.asset.localId == assetId || s.asset.remoteId == assetId);

  VideoSession start({required BaseAsset asset, required String surface, required VideoSessionControls controls}) {
    final session = VideoSession(id: 'vs${++_next}', asset: asset, surface: surface, controls: controls);
    if (asset.width != null && asset.height != null) {
      session.videoSize = Size(asset.width!.toDouble(), asset.height!.toDouble());
    }
    _sessions[session.id] = session;
    _positionThrottles[session.id] = EventThrottle(
      ViewerEventNames.videoPosition,
      ViewerEventNames.throttled[ViewerEventNames.videoPosition]!,
    );
    _frameThrottles[session.id] = EventThrottle(
      ViewerEventNames.videoFrameRect,
      ViewerEventNames.throttled[ViewerEventNames.videoFrameRect]!,
    );
    ViewerEvents.emitAsset(ViewerEventNames.videoSessionStarted, asset, () => session.toJson(withAsset: false));
    notifyListeners();
    return session;
  }

  void end(VideoSession session) {
    if (_sessions.remove(session.id) == null) {
      return;
    }
    _positionThrottles.remove(session.id)?.flush();
    _frameThrottles.remove(session.id)?.dispose();
    if (session.nativeRegistered) {
      unawaited(PluginVideoChannel.unregisterSession(session));
    }
    ViewerEvents.emitAsset(ViewerEventNames.videoSessionEnded, session.asset, () => session.toJson(withAsset: false));
    // Players end their sessions while the widget tree is being torn down; listeners rebuild afterwards.
    scheduleMicrotask(() {
      overlays.dropTarget(session.id);
      notifyListeners();
    });
  }

  void attachView(VideoSession session, int viewId) {
    session.viewId = viewId;
    if (session.nativeRegistered) {
      unawaited(PluginVideoChannel.registerSession(session));
    }
  }

  void setCurrent(VideoSession session, bool isCurrent) {
    if (session.isCurrent == isCurrent) {
      return;
    }
    session.isCurrent = isCurrent;
    // Called from didUpdateWidget (during a build): tell listeners afterwards.
    scheduleMicrotask(notifyListeners);
  }

  /// Reports the player's state; emits `video.state` on changes and `video.position` (throttled) while it moves.
  void report(VideoSession session, {VideoSessionState? state, int? positionMs, int? durationMs, Size? videoSize}) {
    if (!_sessions.containsKey(session.id)) {
      return;
    }
    if (videoSize != null && videoSize.width > 0 && videoSize.height > 0) {
      session.videoSize = videoSize;
    }
    if (durationMs != null && durationMs > 0) {
      session.durationMs = durationMs;
    }
    final stateChanged = state != null && state != session.state;
    final positionChanged = positionMs != null && positionMs != session.reportedPositionMs;
    if (positionChanged || stateChanged) {
      session._setPosition(positionMs ?? session.reportedPositionMs);
    }
    if (stateChanged) {
      session.state = state;
      session.notifyListeners();
      _positionThrottles[session.id]?.flush();
      ViewerEvents.emit(ViewerEventNames.videoState, () => session.toJson(withAsset: false));
      if (session.nativeRegistered) {
        unawaited(PluginVideoChannel.updateSession(session));
      }
    } else if (positionChanged) {
      _positionThrottles[session.id]?.call(
        () => {
          'sessionId': session.id,
          'assetId': session.asset.id,
          'positionMs': session.reportedPositionMs,
          'durationMs': session.durationMs,
          'playing': session.isPlaying,
          'speed': session.speed,
        },
      );
    }
  }

  void reportSpeed(VideoSession session, double speed) {
    session._setPosition(session.positionMs());
    session.speed = speed;
    session.notifyListeners();
    ViewerEvents.emit(ViewerEventNames.videoState, () => session.toJson(withAsset: false));
  }

  void reportVolume(VideoSession session, double volume) {
    session.volume = volume;
    ViewerEvents.emit(ViewerEventNames.videoState, () => session.toJson(withAsset: false));
  }

  /// Reports where the video frame is on screen (global logical pixels) and the player box size.
  void reportFrame(VideoSession session, Rect frameRect, Size boxSize) {
    if (session.frameRect == frameRect && session.boxSize == boxSize) {
      return;
    }
    session.frameRect = frameRect;
    session.boxSize = boxSize;
    _frameThrottles[session.id]?.call(
      () => {
        'sessionId': session.id,
        'assetId': session.asset.id,
        'frameRect': VideoSession.rectJson(frameRect),
        'boxSize': {'width': boxSize.width, 'height': boxSize.height},
      },
    );
    if (session.nativeRegistered) {
      unawaited(PluginVideoChannel.updateSession(session));
    }
  }

  /// Makes sure the native side knows [session] (needed for frame capture and native overlays).
  Future<void> ensureNative(VideoSession session) async {
    if (session.nativeRegistered) {
      return;
    }
    session.nativeRegistered = true;
    try {
      await PluginVideoChannel.registerSession(session);
    } catch (error, stack) {
      session.nativeRegistered = false;
      _log.warning('registerSession failed', error, stack);
      rethrow;
    }
  }

  /// Whether a plugin listens to any video event (used by players to skip work).
  static bool get anyListener =>
      PluginHooks.listens(ViewerEventNames.videoPosition) ||
      PluginHooks.listens(ViewerEventNames.videoState) ||
      PluginHooks.listens(ViewerEventNames.videoFrameRect);
}

/// The Dart side of the `immich/plugin_video` method channel (implemented by the native area in Kotlin).
///
/// Dart → native methods: `registerSession`, `updateSession`, `unregisterSession`, `captureFrame`, `extractFrame`,
/// `attachOverlay`, `detachOverlay`. Every call carries `sessionId` and `viewId` so the native side can find the player
/// view with `flutterEngine.platformViewsController.getPlatformViewById(viewId)` even without keeping state.
abstract final class PluginVideoChannel {
  static const name = 'immich/plugin_video';
  static const _channel = MethodChannel(name);

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static Map<String, dynamic> _session(VideoSession session) => {
    'sessionId': session.id,
    'viewId': session.viewId,
    'assetId': session.asset.id,
    'localId': session.asset.localId,
    'remoteId': session.asset.remoteId,
    'surface': session.surface,
  };

  static Map<String, dynamic> _state(VideoSession session) => {
    'state': session.state.name,
    'positionMs': session.positionMs(),
    'durationMs': session.durationMs,
    'speed': session.speed,
    'volume': session.volume,
    if (session.videoSize != null) 'videoWidth': session.videoSize!.width.round(),
    if (session.videoSize != null) 'videoHeight': session.videoSize!.height.round(),
    if (session.frameRect != null) 'frameRect': VideoSession.rectJson(session.frameRect!),
    'devicePixelRatio': PlatformDispatcher.instance.views.first.devicePixelRatio,
  };

  static Future<T?> _invoke<T>(String method, Map<String, dynamic> args) async {
    if (!isSupported) {
      throw UnsupportedError('$method needs Android');
    }
    return _channel.invokeMethod<T>(method, args);
  }

  static Future<void> registerSession(VideoSession session) =>
      _invoke<void>('registerSession', {..._session(session), ..._state(session)});

  static Future<void> updateSession(VideoSession session) async {
    try {
      await _invoke<void>('updateSession', {..._session(session), ..._state(session)});
    } on MissingPluginException {
      // Older native side: nothing to update.
    } on UnsupportedError {
      // Not Android.
    }
  }

  static Future<void> unregisterSession(VideoSession session) async {
    try {
      await _invoke<void>('unregisterSession', _session(session));
    } on MissingPluginException {
      // Older native side.
    } on UnsupportedError {
      // Not Android.
    }
  }

  /// Copies the current frame of the real player. [width] / [height] default to the video size; `format` is
  /// `rgba` (raw pixels), `png` or `jpeg`. Returns `{ "path", "width", "height", "format", "positionMs" }`.
  static Future<Map<String, dynamic>> captureFrame(
    VideoSession session, {
    int? width,
    int? height,
    String format = 'rgba',
    int quality = 90,
  }) async {
    final result = await _invoke<Map<Object?, Object?>>('captureFrame', {
      ..._session(session),
      'width': ?width,
      'height': ?height,
      'format': format,
      'quality': quality,
      'positionMs': session.positionMs(),
    });
    return _result(result, 'captureFrame');
  }

  /// Decodes the frame at [timeMs] of a video file or URL (no player needed).
  static Future<Map<String, dynamic>> extractFrame({
    String? path,
    String? url,
    Map<String, String> headers = const {},
    String? localId,
    required int timeMs,
    int? width,
    int? height,
    String format = 'rgba',
    int quality = 90,
  }) async {
    final result = await _invoke<Map<Object?, Object?>>('extractFrame', {
      'path': ?path,
      'url': ?url,
      if (headers.isNotEmpty) 'headers': headers,
      'localId': ?localId,
      'timeMs': timeMs,
      'width': ?width,
      'height': ?height,
      'format': format,
      'quality': quality,
    });
    return _result(result, 'extractFrame');
  }

  /// Puts plugin [plugin]'s native view [view] inside the player container, sized and placed exactly over the
  /// video frame, above the video and below Flutter. Returns `{ "overlayId" }`.
  static Future<Map<String, dynamic>> attachOverlay(
    VideoSession session, {
    required String plugin,
    required String view,
    required String id,
    Map<String, dynamic> params = const {},
    bool interactive = false,
  }) async {
    final result = await _invoke<Map<Object?, Object?>>('attachOverlay', {
      ..._session(session),
      ..._state(session),
      'plugin': plugin,
      'view': view,
      'id': id,
      'params': params,
      'interactive': interactive,
    });
    return result == null ? {'overlayId': '$plugin/$id'} : Map<String, dynamic>.from(result);
  }

  static Future<void> detachOverlay(VideoSession session, {required String plugin, String? id}) =>
      _invoke<void>('detachOverlay', {..._session(session), 'plugin': plugin, 'id': ?id});

  static Map<String, dynamic> _result(Map<Object?, Object?>? result, String method) {
    if (result == null) {
      throw StateError('$method returned nothing');
    }
    return Map<String, dynamic>.from(result);
  }
}
