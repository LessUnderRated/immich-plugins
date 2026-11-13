import 'dart:math';

import 'package:async/async.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/colors.dart';
import 'package:immich_mobile/extensions/duration_extensions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/video_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/video_sessions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart';
import 'package:immich_mobile/models/cast/cast_manager_state.dart';
import 'package:immich_mobile/presentation/actions/action_slots.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/widgets/asset_viewer/animated_play_pause.dart';

class VideoControls extends ConsumerStatefulWidget {
  final String videoPlayerName;

  static const List<Shadow> _controlShadows = [Shadow(color: Colors.black87, blurRadius: 6, offset: Offset(0, 1))];

  const VideoControls({super.key, required this.videoPlayerName});

  @override
  ConsumerState<VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends ConsumerState<VideoControls> {
  late final RestartableTimer _hideTimer;

  /// Where a seek drag started, for the `video.control` hook (a cancelled seek jumps back here).
  Duration? _seekFrom;

  AutoDisposeStateNotifierProvider<VideoPlayerNotifier, VideoPlayerState> get _provider =>
      videoPlayerProvider(widget.videoPlayerName);

  @override
  void initState() {
    super.initState();
    _hideTimer = RestartableTimer(const Duration(seconds: 5), _onHideTimer);
  }

  @override
  void didUpdateWidget(covariant VideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPlayerName != widget.videoPlayerName) {
      _hideTimer.reset();
    }
  }

  @override
  void dispose() {
    _hideTimer.cancel();
    super.dispose();
  }

  void _onHideTimer() {
    if (!mounted) {
      return;
    }
    if (ref.read(_provider).status == VideoPlaybackStatus.playing) {
      ref.read(assetViewerProvider.notifier).setControls(false);
    }
  }

  void _toggle(bool isCasting) {
    if (isCasting) {
      ref.read(castProvider.notifier).toggle();
      return;
    }

    final notifier = ref.read(_provider.notifier);
    final asset = ref.read(assetViewerProvider).currentAsset;
    if (!VideoControlHook.isHooked || asset == null) {
      notifier.toggle();
      return;
    }
    final player = ref.read(_provider);
    VideoControlHook.dispatch(
      switch (player.status) {
        VideoPlaybackStatus.paused => 'play',
        VideoPlaybackStatus.playing || VideoPlaybackStatus.buffering => 'pause',
        VideoPlaybackStatus.completed => 'restart',
      },
      asset,
      session: _session,
      positionMs: player.position.inMilliseconds,
      builtin: notifier.toggle,
    );
  }

  VideoSession? get _session {
    VideoSession? found;
    for (final session in VideoSessions.instance.ofAsset(widget.videoPlayerName)) {
      found = session;
      if (session.isCurrent) {
        break;
      }
    }
    return found;
  }

  void _onSeekStart(VideoPlayerNotifier notifier) {
    _seekFrom = ref.read(_provider).position;
    notifier.hold();
  }

  void _onSeekEnd(VideoPlayerNotifier notifier, bool isCasting, double value) {
    notifier.release();
    final from = _seekFrom;
    _seekFrom = null;
    final asset = ref.read(assetViewerProvider).currentAsset;
    if (isCasting || from == null || asset == null || !VideoControlHook.isHooked) {
      return;
    }
    // The seek already happened while dragging; a plugin that cancels or replaces it sends the video back.
    VideoControlHook.dispatch(
      'seek',
      asset,
      session: _session,
      positionMs: Duration(microseconds: value.toInt()).inMilliseconds,
      fromMs: from.inMilliseconds,
      builtin: () {},
      onSkipped: () {
        if (mounted) {
          ref.read(_provider.notifier).seekTo(from);
        }
      },
    );
  }

  void _onSeek(bool isCasting, double value) {
    final seekTo = Duration(microseconds: value.toInt());

    if (isCasting) {
      ref.read(castProvider.notifier).seekTo(seekTo);
      return;
    }

    ref.read(_provider.notifier).seekTo(seekTo);
  }

  @override
  Widget build(BuildContext context) {
    final cast = ref.watch(castProvider);
    final isCasting = cast.isCasting;

    final (position, duration) = isCasting
        ? ref.watch(castProvider.select((c) => (c.currentTime, c.duration)))
        : ref.watch(_provider.select((v) => (v.position, v.duration)));

    final videoStatus = ref.watch(_provider.select((v) => v.status));
    final isPlaying = isCasting
        ? cast.castState == CastState.playing
        : videoStatus == VideoPlaybackStatus.playing || videoStatus == VideoPlaybackStatus.buffering;
    final isFinished = !isCasting && videoStatus == VideoPlaybackStatus.completed;

    ref.listen(assetViewerProvider.select((v) => v.showingControls), (prev, showing) {
      if (showing && prev != showing) {
        _hideTimer.reset();
      }
    });
    ref.listen(_provider.select((v) => v.status), (_, _) => _hideTimer.reset());

    final notifier = ref.watch(_provider.notifier);
    final isLoaded = duration != Duration.zero;

    final session = VideoSessions.instance.sessions
        .where((session) => session.assetId == widget.videoPlayerName)
        .sortedBy<num>((session) => session.isCurrent ? 0 : 1)
        .firstOrNull;
    final slotContext = {
      'sessionId': ?session?.id,
      'assetId': widget.videoPlayerName,
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
      'playing': isPlaying,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 12, 4),
      child: Row(
        // Built-in ids: playPause, scrubber, time; plugin buttons of `videoPlayer.controls` join them.
        children:
            arrangeButtons(ref, ViewerSlotIds.videoControls, [
                  BuiltinSlotItem(
                    id: 'playPause',
                    child: IconButton(
                      iconSize: 22,
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                      visualDensity: VisualDensity.compact,
                      icon: isFinished
                          ? const Icon(Icons.replay, color: Colors.white, shadows: VideoControls._controlShadows)
                          : AnimatedPlayPause(
                              color: Colors.white,
                              playing: isPlaying,
                              shadows: VideoControls._controlShadows,
                            ),
                      onPressed: () => _toggle(isCasting),
                    ),
                  ),
                  BuiltinSlotItem(
                    id: 'scrubber',
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5, disabledThumbRadius: 4),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                        trackShape: const RoundedRectSliderTrackShape(),
                      ),
                      child: Slider(
                        value: min(position.inMicroseconds.toDouble(), duration.inMicroseconds.toDouble()),
                        min: 0,
                        max: max(duration.inMicroseconds.toDouble(), 1),
                        thumbColor: Colors.white,
                        activeColor: Colors.white,
                        inactiveColor: whiteOpacity75.withValues(alpha: 0.35),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        onChangeStart: (_) => _onSeekStart(notifier),
                        onChangeEnd: (value) => _onSeekEnd(notifier, isCasting, value),
                        onChanged: isLoaded ? (value) => _onSeek(isCasting, value) : null,
                      ),
                    ),
                  ),
                  BuiltinSlotItem(
                    id: 'time',
                    child: IgnorePointer(
                      child: Text(
                        "${position.format()} / ${duration.format()}",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          fontFeatures: [FontFeature.tabularFigures()],
                          shadows: VideoControls._controlShadows,
                        ),
                      ),
                    ),
                  ),
                ], context: slotContext)
                // The scrubber takes the remaining width (Expanded must sit directly in the Row).
                .map((item) => slotItemId(item) == 'scrubber' ? Expanded(child: item) : item)
                .toList(),
      ),
    );
  }
}
