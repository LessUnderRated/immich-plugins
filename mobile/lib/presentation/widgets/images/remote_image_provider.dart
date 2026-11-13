import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/image_pipeline.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/images/animated_image_stream_completer.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/one_frame_multi_image_stream_completer.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:openapi/api.dart';

class RemoteImageProvider extends ImageProvider<RemoteImageProvider> {
  final String url;
  final bool edited;

  /// Physical size to decode, or null for the source size.
  final Size? decodeSize;

  /// The asset this is the thumbnail of (for the `image.thumbnail` plugin hook); null for other images
  /// (faces, avatars, ...). Derived from [url], so not part of equality.
  final ImageSubject? subject;

  const RemoteImageProvider({required this.url, this.edited = true, this.decodeSize}) : subject = null;

  RemoteImageProvider.thumbnail({
    required String assetId,
    required String thumbhash,
    this.edited = true,
    this.decodeSize,
    AssetType assetType = AssetType.image,
  }) : url = getThumbnailUrlForRemoteId(assetId, thumbhash: thumbhash, edited: edited),
       subject = ImageSubject(remoteId: assetId, type: assetType);

  @override
  Future<RemoteImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(RemoteImageProvider key, ImageDecoderCallback decode) {
    final loader = ImageLoader(key);
    return OneFramePlaceholderImageStreamCompleter(
      _codec(loader, key, decode),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<String>('URL', key.url),
      ],
      onLastListenerRemoved: loader.cancel,
    );
  }

  Stream<ImageInfo> _codec(ImageLoader loader, RemoteImageProvider key, ImageDecoderCallback decode) {
    final request = loader.request = RemoteImageRequest(uri: key.url, decodeSize: key.decodeSize);
    final subject = key.subject;
    return loader.loadRequest(
      request,
      decode,
      isFinal: true,
      pipeline: subject == null ? null : ImagePipelineTarget(ImageStage.thumbnail, subject),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is RemoteImageProvider) {
      return url == other.url && edited == other.edited && decodeSize == other.decodeSize;
    }
    return false;
  }

  @override
  int get hashCode => url.hashCode ^ edited.hashCode ^ decodeSize.hashCode;
}

class RemoteFullImageProvider extends ImageProvider<RemoteFullImageProvider> {
  final String assetId;
  final String thumbhash;
  final AssetType assetType;
  final bool isAnimated;
  final bool edited;

  /// Physical size of the thumbnail shown before the preview.
  final Size? thumbnailSize;

  const RemoteFullImageProvider({
    required this.assetId,
    required this.thumbhash,
    required this.assetType,
    required this.isAnimated,
    this.edited = true,
    this.thumbnailSize,
  });

  @override
  Future<RemoteFullImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  ImagePipelineTarget _pipeline(ImageStage stage) =>
      ImagePipelineTarget(stage, ImageSubject(remoteId: assetId, type: assetType));

  ImageStage get _finalStage => assetType == AssetType.image && SettingsRepository.instance.appConfig.image.loadOriginal
      ? ImageStage.full
      : ImageStage.preview;

  @override
  ImageStreamCompleter loadImage(RemoteFullImageProvider key, ImageDecoderCallback decode) {
    final loader = ImageLoader(key);
    if (key.isAnimated) {
      return AnimatedImageStreamCompleter(
        stream: _animatedCodec(loader, key, decode),
        scale: 1.0,
        initialImage: ImagePipeline.placeholder(
          loader.getInitialImage(
            RemoteImageProvider.thumbnail(
              assetId: key.assetId,
              thumbhash: key.thumbhash,
              decodeSize: key.thumbnailSize,
            ),
          ),
          ImageStage.full,
        ),
        informationCollector: () => <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<String>('Asset Id', key.assetId),
          DiagnosticsProperty<bool>('isAnimated', key.isAnimated),
        ],
        onLastListenerRemoved: loader.cancel,
      );
    }

    return OneFramePlaceholderImageStreamCompleter(
      _codec(loader, key, decode),
      initialImage: ImagePipeline.placeholder(
        loader.getInitialImage(
          RemoteImageProvider.thumbnail(
            assetId: key.assetId,
            thumbhash: key.thumbhash,
            edited: key.edited,
            decodeSize: key.thumbnailSize,
          ),
        ),
        key._finalStage,
      ),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<String>('Asset Id', key.assetId),
        DiagnosticsProperty<bool>('isAnimated', key.isAnimated),
      ],
      onLastListenerRemoved: loader.cancel,
    );
  }

  Stream<ImageInfo> _codec(ImageLoader loader, RemoteFullImageProvider key, ImageDecoderCallback decode) async* {
    yield* loader.initialImageStream();

    if (loader.isCancelled) {
      return;
    }

    final previewRequest = loader.request = _previewRequest(key);
    final loadOriginal = assetType == AssetType.image && SettingsRepository.instance.appConfig.image.loadOriginal;
    yield* loader.loadRequest(
      previewRequest,
      decode,
      isFinal: !loadOriginal,
      pipeline: key._pipeline(ImageStage.preview),
      finalStage: loadOriginal ? ImageStage.full : ImageStage.preview,
    );

    if (!loadOriginal) {
      return;
    }

    if (loader.isCancelled) {
      return;
    }

    final originalRequest = loader.request = _originalRequest(key);
    yield* loader.loadRequest(originalRequest, decode, isFinal: true, pipeline: key._pipeline(ImageStage.full));
  }

  Stream<Object> _animatedCodec(ImageLoader loader, RemoteFullImageProvider key, ImageDecoderCallback decode) async* {
    yield* loader.initialImageStream();

    if (loader.isCancelled) {
      return;
    }

    final previewRequest = loader.request = _previewRequest(key);
    yield* loader.loadRequest(
      previewRequest,
      decode,
      isFinal: false,
      pipeline: key._pipeline(ImageStage.preview),
      finalStage: ImageStage.full,
    );

    if (loader.isCancelled) {
      return;
    }

    // always try original for animated, since previews don't support animation
    final originalRequest = loader.request = _originalRequest(key);
    final codec = await loader.loadCodecRequest(
      originalRequest,
      isFinal: true,
      pipeline: key._pipeline(ImageStage.full),
      reload: () => _originalRequest(key),
    );
    if (codec == null) {
      if (loader.isCancelled) {
        return;
      }
      throw StateError('Failed to load animated codec for asset ${key.assetId}');
    }
    yield codec;
  }

  RemoteImageRequest _previewRequest(RemoteFullImageProvider key) => RemoteImageRequest(
    uri: getThumbnailUrlForRemoteId(
      key.assetId,
      type: AssetMediaSize.preview,
      thumbhash: key.thumbhash,
      edited: key.edited,
    ),
  );

  RemoteImageRequest _originalRequest(RemoteFullImageProvider key) =>
      RemoteImageRequest(uri: getOriginalUrlForRemoteId(key.assetId, edited: key.edited));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is RemoteFullImageProvider) {
      return assetId == other.assetId &&
          thumbhash == other.thumbhash &&
          isAnimated == other.isAnimated &&
          edited == other.edited;
    }

    return false;
  }

  @override
  int get hashCode => assetId.hashCode ^ thumbhash.hashCode ^ isAnimated.hashCode ^ edited.hashCode;
}
