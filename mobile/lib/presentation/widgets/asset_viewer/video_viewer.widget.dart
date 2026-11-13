import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/video_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/video_sessions.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/plugin_video_player_view.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_overlay_layer.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_censor.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/viewer_censor.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';

class NativeVideoViewer extends ConsumerStatefulWidget {
  final BaseAsset asset;
  final String? localFilePath;
  final bool isCurrent;
  final Widget image;

  /// Overrides the user's configured loop video setting
  final bool? loopOverride;

  /// Where the player is shown (`viewer`, `slideshow` or `memory`), for plugins' video sessions.
  final String surface;

  const NativeVideoViewer({
    super.key,
    required this.asset,
    this.localFilePath,
    required this.image,
    this.isCurrent = false,
    this.loopOverride,
    this.surface = 'viewer',
  });

  @override
  ConsumerState<NativeVideoViewer> createState() => NativeVideoViewerState();
}

class NativeVideoViewerState extends ConsumerState<NativeVideoViewer> with WidgetsBindingObserver {
  static final _log = Logger('NativeVideoViewer');

  NativeVideoPlayerController? _controller;
  @visibleForTesting
  late final Future<VideoSource?> videoSource;
  Timer? _loadTimer;
  bool _isVideoReady = false;
  bool _shouldPlayOnForeground = true;

  /// The plugin video session of this player (from the moment the native view exists until dispose).
  VideoSession? _session;

  VideoPlayerNotifier get _notifier => ref.read(videoPlayerProvider(widget.asset.id).notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    videoSource = _createSource();
  }

  @override
  void didUpdateWidget(NativeVideoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isCurrent == oldWidget.isCurrent || _controller == null) {
      return;
    }

    final session = _session;
    if (session != null) {
      VideoSessions.instance.setCurrent(session, widget.isCurrent);
    }

    if (!widget.isCurrent) {
      _loadTimer?.cancel();
      unawaited(_notifier.pause());
      return;
    }

    // Prevent unnecessary loading when swiping between assets.
    _loadTimer = Timer(const Duration(milliseconds: 200), _loadVideo);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loadTimer?.cancel();
    _removeListeners();
    final session = _session;
    if (session != null) {
      _session = null;
      VideoSessions.instance.end(session);
    }
    super.dispose();
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_shouldPlayOnForeground) {
          await _notifier.play();
        }
      case AppLifecycleState.paused:
        _shouldPlayOnForeground = await _controller?.isPlaying() ?? true;
        if (_shouldPlayOnForeground && mounted) {
          await _notifier.pause();
        }
      default:
    }
  }

  Future<VideoSource?> _createSource() async {
    if (!mounted) {
      return null;
    }

    final videoAsset = await ref.read(assetServiceProvider).getAsset(widget.asset) ?? widget.asset;
    if (!mounted) {
      return null;
    }

    try {
      final storageRepository = ref.read(storageRepositoryProvider);
      final localFilePath = widget.localFilePath;
      if (localFilePath != null) {
        final file = File(localFilePath);
        // ignore: avoid_slow_async_io
        if (!await file.exists()) {
          throw Exception('No file found for the video');
        }

        return await _initSource(
          path: CurrentPlatform.isAndroid ? file.uri.toString() : file.path,
          type: VideoSourceType.file,
        );
      }

      // Attempt to retrieve LocalAsset, falling back to remote if it cannot be found
      final localAsset = await _localPlaybackAsset(videoAsset);

      if (localAsset != null) {
        final file = localAsset.isMotionPhoto
            ? await storageRepository.getMotionFileForAsset(localAsset)
            : await storageRepository.getFileForAsset(localAsset.id);

        if (!mounted) {
          return null;
        }

        // Pass a file:// URI so Android's Uri.parse doesn't
        // interpret characters like '#' as fragment identifiers.
        if (file != null) {
          return await _initSource(
            path: CurrentPlatform.isAndroid ? file.uri.toString() : file.path,
            type: VideoSourceType.file,
          );
        }

        if (videoAsset is! RemoteAsset) {
          throw Exception('No file found for the video');
        }
        _log.warning('Local file missing for ${videoAsset.name} (${videoAsset.localId}), playing the remote copy');
      }

      final remoteAsset = videoAsset as RemoteAsset;

      final serverEndpoint = Store.get(StoreKey.serverEndpoint);
      if (!context.mounted) {
        return null;
      }

      final isOriginalVideo = ref.read(appConfigProvider).viewer.loadOriginalVideo;
      final String postfixUrl = isOriginalVideo ? 'original' : 'video/playback';
      final String assetId = remoteAsset.livePhotoVideoId ?? remoteAsset.id;
      final String videoUrl = '$serverEndpoint/assets/$assetId/$postfixUrl';

      return await _initSource(path: videoUrl, type: VideoSourceType.network, headers: ApiService.getRequestHeaders());
    } catch (error) {
      _log.severe('Error creating video source for asset ${videoAsset.name}: $error');
      return null;
    }
  }

  /// `VideoSource.init` through the `video.source` hook (a plain call when no plugin hooks it).
  Future<VideoSource> _initSource({required String path, required VideoSourceType type, Map<String, String>? headers}) {
    if (!VideoSourceHook.isHooked) {
      return VideoSource.init(path: path, type: type, headers: headers);
    }
    return VideoSourceHook.resolve(widget.asset, (path: path, type: type.name, headers: headers ?? const {})).then(
      (source) => VideoSource.init(
        path: source.path,
        type: VideoSourceType.values.firstWhere((t) => t.name == source.type, orElse: () => type),
        headers: source.headers,
      ),
    );
  }

  Future<LocalAsset?> _localPlaybackAsset(BaseAsset baseAsset) async {
    if (!baseAsset.hasLocal) {
      return null;
    }

    LocalAsset? localAsset;

    if (baseAsset is LocalAsset) {
      localAsset = baseAsset;
    } else {
      final localId = (baseAsset as RemoteAsset).localId;
      localAsset = localId != null ? await ref.read(assetServiceProvider).getLocalAsset(localId) : null;
    }

    if (localAsset == null) {
      _log.severe(
        'Invariant violation: asset ${baseAsset.name} (${baseAsset.localId}) is marked `hasLocal` but local asset could not be retrieved',
      );

      return null;
    }

    // Clients (local) may not correctly recognize a given asset as a motion photo. This allows for a scenario where both remote and local
    // have the same asset (hash), but only the remote properly recognizes it as a motion asset
    // If this scenario occurs, fall back to using the remote asset
    if (baseAsset.isMotionPhoto && !localAsset.isMotionPhoto) {
      // Platform mismatch for motion photo, use remote instead
      _log.warning(
        'Mismatched local and remote motion states on ${baseAsset.name} (${baseAsset.localId}), local = ${localAsset.isMotionPhoto}, remote = ${baseAsset.isMotionPhoto}',
      );

      return null;
    }

    return localAsset;
  }

  Future<void> _onPlaybackReady() async {
    if (!mounted || !widget.isCurrent) {
      return;
    }

    _notifier.onNativePlaybackReady();
    _reportSession();

    // onPlaybackReady may be called multiple times, usually when more data
    // loads. If this is not the first time that the player has become ready, we
    // should not autoplay.
    if (_isVideoReady) {
      return;
    }

    setState(() => _isVideoReady = true);

    if (ref.read(assetViewerProvider).showingDetails) {
      return;
    }

    final autoPlayVideo = ref.read(appConfigProvider).viewer.autoPlayVideo;
    if (autoPlayVideo || widget.asset.isMotionPhoto) {
      await _notifier.play();
    }
  }

  void _onPlaybackEnded() {
    if (!mounted) {
      return;
    }

    _notifier.onNativePlaybackEnded();
    _reportSession();

    if (_controller?.playbackInfo?.status == PlaybackStatus.stopped) {
      ref.read(isPlayingMotionVideoProvider.notifier).playing = false;
    }
  }

  void _onPlaybackPositionChanged() {
    if (!mounted) {
      return;
    }
    _notifier.onNativePositionChanged();
    _reportSession();
  }

  void _onPlaybackStatusChanged() {
    if (!mounted) {
      return;
    }
    _notifier.onNativeStatusChanged();
    _reportSession();
  }

  void _onPlaybackError() {
    final session = _session;
    if (!mounted || session == null || _controller?.onError.value == null) {
      return;
    }
    VideoSessions.instance.report(session, state: VideoSessionState.error);
  }

  /// Tells the plugin video session what the player is doing.
  void _reportSession() {
    final session = _session;
    if (session == null || !mounted) {
      return;
    }
    final player = ref.read(videoPlayerProvider(widget.asset.id));
    final videoInfo = _controller?.videoInfo;
    VideoSessions.instance.report(
      session,
      state: !_isVideoReady && player.status == VideoPlaybackStatus.paused
          ? (videoInfo == null ? VideoSessionState.loading : VideoSessionState.ready)
          : switch (player.status) {
              VideoPlaybackStatus.paused => VideoSessionState.paused,
              VideoPlaybackStatus.playing => VideoSessionState.playing,
              VideoPlaybackStatus.buffering => VideoSessionState.buffering,
              VideoPlaybackStatus.completed => VideoSessionState.completed,
            },
      positionMs: player.position.inMilliseconds,
      durationMs: player.duration.inMilliseconds,
      videoSize: videoInfo == null ? null : Size(videoInfo.width.toDouble(), videoInfo.height.toDouble()),
    );
  }

  void _removeListeners() {
    _controller?.onPlaybackPositionChanged.removeListener(_onPlaybackPositionChanged);
    _controller?.onPlaybackStatusChanged.removeListener(_onPlaybackStatusChanged);
    _controller?.onPlaybackReady.removeListener(_onPlaybackReady);
    _controller?.onPlaybackEnded.removeListener(_onPlaybackEnded);
    _controller?.onError.removeListener(_onPlaybackError);
  }

  Future<void> _loadVideo() async {
    final nc = _controller;
    if (nc == null || nc.videoSource != null || !mounted) {
      return;
    }

    final source = await videoSource;
    if (source == null || !mounted) {
      return;
    }

    // Grab refs to prevent reading after dispose
    final loopVideo = widget.loopOverride ?? ref.read(appConfigProvider).viewer.loopVideo;
    final localNotifier = _notifier;

    await localNotifier.load(source);
    await localNotifier.setLoop(!widget.asset.isMotionPhoto && loopVideo);
    await localNotifier.setVolume(1);
  }

  void _initController(NativeVideoPlayerController nc, int viewId) {
    if (_controller != null || !mounted) {
      return;
    }

    _notifier.attachController(nc);

    nc.onPlaybackPositionChanged.addListener(_onPlaybackPositionChanged);
    nc.onPlaybackStatusChanged.addListener(_onPlaybackStatusChanged);
    nc.onPlaybackReady.addListener(_onPlaybackReady);
    nc.onPlaybackEnded.addListener(_onPlaybackEnded);
    nc.onError.addListener(_onPlaybackError);

    _controller = nc;

    final session = VideoSessions.instance.start(
      asset: widget.asset,
      surface: widget.surface,
      controls: _VideoSessionControls(this),
    );
    VideoSessions.instance
      ..attachView(session, viewId)
      ..setCurrent(session, widget.isCurrent);
    setState(() => _session = session);

    if (widget.isCurrent) {
      unawaited(_loadVideo());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCasting = ref.watch(castProvider.select((c) => c.isCasting));
    final status = ref.watch(videoPlayerProvider(widget.asset.id).select((v) => v.status));
    // https://github.com/flutter/flutter/issues/97499: iOS platform views are only disposed in frames containing platform views, or on
    // the first frame after a platform view disappears. Animating this view away uses those disappearing frames. Instead, forcibly remove
    // the view from the tree when we start a route transition, which has the side effect of properly ordering the `dispose`
    final isRouteActive = ModalRoute.of(context)?.isActive ?? true;
    final showPlayer = !isCasting && isRouteActive;
    final asset = widget.asset;
    final localId = asset is LocalAsset ? asset.id : (asset is RemoteAsset ? asset.localId : null);
    final censorAssetId = ref.watch(viewerCensorActiveProvider) && !asset.isMotionPhoto ? localId : null;

    return IgnorePointer(
      child: Stack(
        children: [
          if (!_isVideoReady || widget.asset.isMotionPhoto || !showPlayer) Positioned.fill(child: widget.image),
          if (showPlayer) ...[
            Visibility.maintain(
              visible: _isVideoReady,
              child: VideoFrameReporter(
                session: _session,
                child: PluginVideoPlayerView(onViewReady: _initController),
              ),
            ),
            Positioned.fill(child: _session == null ? const SizedBox.shrink() : VideoOverlayLayer(session: _session!)),
            if (censorAssetId != null)
              Positioned.fill(
                child: VideoCensorOverlay(assetId: censorAssetId, controller: _controller),
              ),
            Center(
              child: AnimatedOpacity(
                opacity: status == VideoPlaybackStatus.buffering ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 400),
                child: const CircularProgressIndicator(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Plugin control of the player behind a video session (`video.play`, `video.seek`, ...).
class _VideoSessionControls implements VideoSessionControls {
  final NativeVideoViewerState _state;

  const _VideoSessionControls(this._state);

  VideoPlayerNotifier? get _notifier => _state.mounted ? _state._notifier : null;

  @override
  Future<void> play() async => _notifier?.play();

  @override
  Future<void> pause() async => _notifier?.pause();

  @override
  Future<void> seek(Duration position) async => _notifier?.seekTo(position);

  @override
  Future<void> setSpeed(double speed) async {
    final controller = _state._controller;
    final session = _state._session;
    if (controller == null || session == null) {
      return;
    }
    await controller.setPlaybackSpeed(speed);
    VideoSessions.instance.reportSpeed(session, speed);
  }

  @override
  Future<void> setVolume(double volume) async {
    final session = _state._session;
    await _notifier?.setVolume(volume);
    if (session != null) {
      VideoSessions.instance.reportVolume(session, volume);
    }
  }
}
