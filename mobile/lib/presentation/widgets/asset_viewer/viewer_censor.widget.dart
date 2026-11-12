import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/plugins/viewer_filter.dart';
import 'package:immich_mobile/presentation/pages/plugins/schema_form.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/providers/viewer_censor.provider.dart';
import 'package:native_video_player/native_video_player.dart';

const _blurSigma = 28.0;

class UiImageProvider extends ImageProvider<UiImageProvider> {
  final ui.Image image;
  final Object id;

  const UiImageProvider(this.image, {required this.id});

  @override
  Future<UiImageProvider> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(UiImageProvider key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image.clone())));

  @override
  bool operator ==(Object other) => other is UiImageProvider && other.id == id && identical(other.image, image);

  @override
  int get hashCode => Object.hash(id, image);
}

class ViewerCensorButton extends ConsumerWidget {
  const ViewerCensorButton({super.key});

  Future<void> _settings(BuildContext context, WidgetRef ref) async {
    final schema = await ref.read(viewerFilterProvider).schema();
    if (!context.mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => Consumer(
        builder: (context, ref, _) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Censor while viewing', style: Theme.of(context).textTheme.titleMedium),
                SchemaForm(
                  schema: schema,
                  config: ref.watch(viewerCensorConfigProvider),
                  onChanged: ref.read(viewerCensorConfigProvider.notifier).set,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(ref.watch(viewerFilterAvailableProvider).valueOrNull ?? false)) {
      return const SizedBox.shrink();
    }
    final enabled = ref.watch(viewerCensorEnabledProvider);
    return GestureDetector(
      onLongPress: () => _settings(context, ref),
      child: IconButton(
        tooltip: enabled ? 'Censor on (hold for settings)' : 'Censor off (hold for settings)',
        icon: Icon(enabled ? Icons.shield : Icons.remove_moderator_outlined),
        onPressed: ref.read(viewerCensorEnabledProvider.notifier).toggle,
      ),
    );
  }
}

class CensoredPhoto extends ConsumerWidget {
  final BaseAsset asset;
  final Widget Function() original;
  final Widget Function(ImageProvider provider) censored;

  const CensoredPhoto({super.key, required this.asset, required this.original, required this.censored});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localId = asset is LocalAsset ? asset.id : (asset is RemoteAsset ? (asset as RemoteAsset).localId : null);
    if (localId == null) {
      return original();
    }

    final result = ref.watch(censoredPhotoProvider(localId));
    return result.when(
      data: (image) => image == null ? original() : censored(UiImageProvider(image, id: localId)),
      loading: () => _BlurredPlaceholder(asset: asset, busy: true),
      error: (_, _) => _BlurredPlaceholder(asset: asset, busy: false),
    );
  }
}

class _BlurredPlaceholder extends StatelessWidget {
  final BaseAsset asset;
  final bool busy;

  const _BlurredPlaceholder({required this.asset, required this.busy});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma, tileMode: TileMode.decal),
          child: Thumbnail.fromAsset(asset: asset, fit: BoxFit.contain),
        ),
        Center(
          child: busy
              ? const CircularProgressIndicator()
              : const Icon(Icons.error_outline, color: Colors.white70, size: 40),
        ),
      ],
    );
  }
}

class VideoCensorOverlay extends ConsumerStatefulWidget {
  final String assetId;
  final NativeVideoPlayerController? controller;

  const VideoCensorOverlay({super.key, required this.assetId, required this.controller});

  @override
  ConsumerState<VideoCensorOverlay> createState() => _VideoCensorOverlayState();
}

class _VideoCensorOverlayState extends ConsumerState<VideoCensorOverlay> {
  static const _stepMs = 500;
  static const _windowMs = 4000;
  static const _lookaheadMs = 2500;

  final List<VideoCensorFrame> _frames = [];
  Timer? _timer;
  bool _analyzing = false;
  bool _failed = false;
  int _position = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) => _tick());
    _tick();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  VideoCensorFrame? _frameAt(int position) =>
      _frames.lastWhereOrNull((frame) => frame.timeMs <= position && position - frame.timeMs <= _stepMs * 2);

  void _tick() {
    final position = widget.controller?.playbackInfo?.position ?? 0;
    if (position != _position && mounted) {
      setState(() => _position = position);
    }
    if (_analyzing || _failed) {
      return;
    }

    final start = (position ~/ _stepMs) * _stepMs;
    if (_frameAt(position) == null) {
      unawaited(_analyze(start));
      return;
    }
    final last = _frames.where((frame) => frame.timeMs >= start).map((frame) => frame.timeMs).fold(start, max);
    if (last < position + _lookaheadMs) {
      unawaited(_analyze(last + _stepMs));
    }
  }

  Future<void> _analyze(int fromMs) async {
    _analyzing = true;
    try {
      final frames = await ref
          .read(viewerFilterProvider)
          .analyzeVideo(
            widget.assetId,
            ref.read(viewerCensorConfigProvider),
            fromMs: fromMs,
            toMs: fromMs + _windowMs,
            stepMs: _stepMs,
          );
      if (!mounted) {
        return;
      }
      setState(() {
        final times = {for (final frame in frames) frame.timeMs};
        _frames
          ..removeWhere((frame) => times.contains(frame.timeMs))
          ..addAll(frames.isEmpty ? [VideoCensorFrame(fromMs, const [])] : frames)
          ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
      });
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
      }
    } finally {
      _analyzing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frameAt(_position);
    final blur = ui.ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma);
    if (frame == null) {
      return ClipRect(
        child: BackdropFilter(filter: blur, child: const SizedBox.expand()),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          for (final region in frame.regions)
            Positioned(
              left: region.rect.left * constraints.maxWidth,
              top: region.rect.top * constraints.maxHeight,
              width: region.rect.width * constraints.maxWidth,
              height: region.rect.height * constraints.maxHeight,
              child: region.ellipse
                  ? ClipOval(
                      child: BackdropFilter(filter: blur, child: const SizedBox.expand()),
                    )
                  : ClipRect(
                      child: BackdropFilter(filter: blur, child: const SizedBox.expand()),
                    ),
            ),
        ],
      ),
    );
  }
}
