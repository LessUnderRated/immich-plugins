import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:native_video_player/native_video_player.dart';

/// `NativeVideoPlayerView` (same platform view, same composition) that also reports the platform view id.
///
/// The id is what the native side needs to find the real player view
/// (`flutterEngine.platformViewsController.getPlatformViewById(viewId)`) for frame capture and native overlays.
class PluginVideoPlayerView extends StatefulWidget {
  final void Function(NativeVideoPlayerController controller, int viewId) onViewReady;

  const PluginVideoPlayerView({super.key, required this.onViewReady});

  @override
  State<PluginVideoPlayerView> createState() => _PluginVideoPlayerViewState();
}

class _PluginVideoPlayerViewState extends State<PluginVideoPlayerView> {
  static const _viewType = 'native_video_player_view';

  NativeVideoPlayerController? _controller;

  @override
  void dispose() {
    // Same ownership as NativeVideoPlayerView: the view disposes the controller it created.
    // ignore: invalid_use_of_protected_member
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(child: _buildNativeView());

  Widget _buildNativeView() => switch (defaultTargetPlatform) {
    TargetPlatform.iOS => UiKitView(viewType: _viewType, onPlatformViewCreated: _onPlatformViewCreated),
    TargetPlatform.android => PlatformViewLink(
      viewType: _viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
      onCreatePlatformView: (params) {
        final controller =
            PlatformViewsService.initSurfaceAndroidView(
                id: params.id,
                viewType: _viewType,
                layoutDirection: TextDirection.ltr,
                onFocus: () => params.onFocusChanged(true),
              )
              ..addOnPlatformViewCreatedListener(_onPlatformViewCreated)
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
        unawaited(controller.create());
        return controller;
      },
    ),
    _ => Text('$defaultTargetPlatform is not yet supported by this plugin.'),
  };

  void _onPlatformViewCreated(int id) {
    // The package creates its controller the same way in NativeVideoPlayerView.
    final controller = NativeVideoPlayerController(id);
    _controller = controller;
    widget.onViewReady(controller, id);
  }
}
