import 'dart:async';
import 'dart:ui';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_bridge.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart';
import 'package:logging/logging.dart';

enum ViewerGestureKind { tap, doubleTap, longPress, swipeUp, swipeDown, pinch }

/// Where the gesture happened (surface `viewer`, `slideshow` or `memory`).
class ViewerGesture {
  final ViewerGestureKind kind;
  final String surface;

  /// Logical pixels inside the page (null when the recognizer gives no position, e.g. a pinch's end).
  final Offset? position;
  final Size viewport;

  /// The photo is zoomed in.
  final bool zoomed;

  /// Pinch: the scale before and after the gesture (1 = fit).
  final double? scale;
  final double? previousScale;

  /// Swipe: the drag distance (logical pixels, positive down) and velocity (pixels per second, positive down).
  final double? distance;
  final double? velocity;

  const ViewerGesture({
    required this.kind,
    required this.viewport,
    this.surface = 'viewer',
    this.position,
    this.zoomed = false,
    this.scale,
    this.previousScale,
    this.distance,
    this.velocity,
  });

  /// `left` / `right` for the outer quarters of the page (the tap-to-navigate zones), `center` otherwise.
  String? get zone {
    final position = this.position;
    if (position == null || viewport.width <= 0) {
      return null;
    }
    if (position.dx < viewport.width / 4) {
      return 'left';
    }
    if (position.dx > viewport.width * 3 / 4) {
      return 'right';
    }
    return 'center';
  }

  Map<String, dynamic> toJson() {
    final position = this.position;
    return {
      'gesture': kind.name,
      'surface': surface,
      'viewport': {'width': viewport.width, 'height': viewport.height},
      'zoomed': zoomed,
      if (position != null) ...{
        'x': viewport.width > 0 ? position.dx / viewport.width : 0,
        'y': viewport.height > 0 ? position.dy / viewport.height : 0,
        'px': {'x': position.dx, 'y': position.dy},
        'zone': zone,
      },
      'scale': ?scale,
      'previousScale': ?previousScale,
      'distance': ?distance,
      'velocity': ?velocity,
    };
  }
}

/// The `viewer.gesture` hook around the viewer's built-in gesture handling.
abstract final class ViewerGestures {
  static final _log = Logger('ViewerGestures');

  static bool get isHooked => PluginHooks.has(ViewerHookIds.gesture);

  /// Runs [builtin] for [gesture]. Without a plugin on `viewer.gesture` this is a plain synchronous call.
  ///
  /// With one, `before` may cancel (then [onSkipped] runs and [onMessage] gets the plugin's message), `instead` may
  /// replace the built-in handling (then [onSkipped] runs too) and `after` is told what happened. The built-in result
  /// is `{ "handled": "builtin" }`.
  static void dispatch(
    ViewerGesture gesture,
    BaseAsset? asset,
    void Function() builtin, {
    void Function()? onSkipped,
    void Function(String message)? onMessage,
  }) {
    if (!isHooked) {
      builtin();
      return;
    }
    unawaited(_run(gesture, asset, builtin, onSkipped: onSkipped, onMessage: onMessage));
  }

  static Future<void> _run(
    ViewerGesture gesture,
    BaseAsset? asset,
    void Function() builtin, {
    void Function()? onSkipped,
    void Function(String message)? onMessage,
  }) async {
    final assetJson = asset == null ? null : await ViewerPlugins.assetJson(asset);
    var ran = false;
    try {
      await PluginHooks.run<Map<String, dynamic>?>(
        ViewerHookIds.gesture,
        () => {...gesture.toJson(), 'asset': assetJson},
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
        _log.warning('viewer.gesture failed', error, stack);
        if (!ran) {
          ran = true;
          builtin();
        }
      }
    }
    if (!ran) {
      onSkipped?.call();
    }
  }
}
