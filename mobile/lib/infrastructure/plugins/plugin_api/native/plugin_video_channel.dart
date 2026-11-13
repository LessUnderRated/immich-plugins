import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A frame captured from a playing video.
class PluginVideoFrame {
  final String path;
  final int width;
  final int height;

  /// `rgba` (raw RGBA8888, width * height * 4 bytes), `png` or `jpeg`.
  final String format;
  final int positionMs;

  const PluginVideoFrame({
    required this.path,
    required this.width,
    required this.height,
    required this.format,
    required this.positionMs,
  });

  factory PluginVideoFrame.fromMap(Map<dynamic, dynamic> map) => PluginVideoFrame(
    path: map['path'] as String,
    width: (map['width'] as num).toInt(),
    height: (map['height'] as num).toInt(),
    format: map['format'] as String,
    positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
  );
}

/// Carries out a playback control a native plugin asked for: [action] is `play`, `pause`, `seek` (value: ms),
/// `speed` (value: double) or `volume` (value: 0..1).
typedef PluginVideoControl = FutureOr<void> Function(String action, Object? value);

/// Dart side of the `immich/plugin_video` channel: the app's video players register every playing video as a
/// session so native plugins can capture frames, place native overlays over the video and control playback.
/// Android only; a no-op elsewhere.
///
/// Usage by a player: when its native view is created, [registerSession] with the platform view id; while playing,
/// [position] (on every position or state change; 4/s or more is fine); on dispose, [unregisterSession].
class PluginVideoChannel {
  PluginVideoChannel._();

  static final PluginVideoChannel instance = PluginVideoChannel._();

  static const channel = MethodChannel('immich/plugin_video');

  final Map<String, PluginVideoControl> _controls = {};
  bool _handlerSet = false;

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// Registers a playing video. [viewId] is the Flutter platform view id of the player (the id passed to
  /// `onPlatformViewCreated`). Returns `{ sessionId, viewId, assetId, bound, surface, frame, positionMs, playing }`;
  /// `bound` is false while the native view is not found yet (the native side keeps trying for 2 s).
  Future<Map<String, dynamic>> registerSession({
    required String sessionId,
    required int viewId,
    String? assetId,
    int? durationMs,
    int? videoWidth,
    int? videoHeight,
    PluginVideoControl? onControl,
  }) async {
    if (!isSupported) {
      return const {};
    }
    if (onControl != null) {
      _controls[sessionId] = onControl;
    }
    if (!_handlerSet) {
      _handlerSet = true;
      channel.setMethodCallHandler(_handle);
    }
    final result = await channel.invokeMapMethod<String, dynamic>('registerSession', {
      'sessionId': sessionId,
      'viewId': viewId,
      'assetId': assetId,
      'durationMs': durationMs,
      'videoWidth': videoWidth,
      'videoHeight': videoHeight,
    });
    return result ?? const {};
  }

  /// Ends the session: native overlays are removed, frames deleted and native listeners told.
  Future<void> unregisterSession(String sessionId) async {
    _controls.remove(sessionId);
    if (!isSupported) {
      return;
    }
    await channel.invokeMethod<void>('unregisterSession', {'sessionId': sessionId});
  }

  /// Playback state. Native code extrapolates the position between updates while [playing].
  Future<void> position(
    String sessionId, {
    required int positionMs,
    required bool playing,
    double? speed,
    int? durationMs,
    int? videoWidth,
    int? videoHeight,
  }) async {
    if (!isSupported) {
      return;
    }
    await channel.invokeMethod<void>('position', {
      'sessionId': sessionId,
      'positionMs': positionMs,
      'playing': playing,
      'speed': speed,
      'durationMs': durationMs,
      'videoWidth': videoWidth,
      'videoHeight': videoHeight,
    });
  }

  /// Copies the current frame from the real player at any size (0 or null: the video's size; one side only keeps
  /// the aspect ratio). The file is deleted when the session ends unless [path] is given.
  Future<PluginVideoFrame> captureFrame(
    String sessionId, {
    int? width,
    int? height,
    String format = 'rgba',
    int quality = 90,
    String? path,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('Video frame capture is only available on Android');
    }
    final result = await channel.invokeMapMethod<String, dynamic>('captureFrame', {
      'sessionId': sessionId,
      'width': width,
      'height': height,
      'format': format,
      'quality': quality,
      'path': path,
    });
    if (result == null) {
      throw StateError('Frame capture returned nothing');
    }
    return PluginVideoFrame.fromMap(result);
  }

  /// Creates native view [view] of [plugin] (ImmichVideoOverlayPlugin or ImmichViewPlugin) and places it exactly
  /// over the video frame, above the video and below Flutter UI. Replaces an earlier one with the same plugin/view.
  Future<void> attachOverlay(
    String sessionId, {
    required String plugin,
    required String view,
    Map<String, dynamic> params = const {},
  }) async {
    if (!isSupported) {
      return;
    }
    await channel.invokeMethod<void>('attachOverlay', {
      'sessionId': sessionId,
      'plugin': plugin,
      'view': view,
      'params': params,
    });
  }

  Future<void> detachOverlay(String sessionId, {required String plugin, required String view}) async {
    if (!isSupported) {
      return;
    }
    await channel.invokeMethod<void>('detachOverlay', {'sessionId': sessionId, 'plugin': plugin, 'view': view});
  }

  Future<List<Map<String, dynamic>>> sessions() async {
    if (!isSupported) {
      return const [];
    }
    final result = await channel.invokeListMethod<Object?>('sessions');
    return [
      for (final session in result ?? const <Object?>[])
        if (session is Map) Map<String, dynamic>.from(session),
    ];
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'control') {
      throw MissingPluginException(call.method);
    }
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final control = _controls[args['sessionId']];
    if (control == null) {
      return false;
    }
    await control(args['action'] as String, args['value']);
    return true;
  }
}
