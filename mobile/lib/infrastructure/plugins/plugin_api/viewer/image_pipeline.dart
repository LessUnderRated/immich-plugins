import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_bridge.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The three image hooks, from smallest to largest.
enum ImageStage {
  thumbnail(ViewerHookIds.imageThumbnail),
  preview(ViewerHookIds.imagePreview),
  full(ViewerHookIds.imageFull);

  const ImageStage(this.hookId);

  final String hookId;
}

/// The asset an image request shows.
@immutable
class ImageSubject {
  final String? localId;
  final String? remoteId;
  final String? checksum;
  final AssetType type;

  const ImageSubject({this.localId, this.remoteId, this.checksum, required this.type});

  factory ImageSubject.of(BaseAsset asset) =>
      ImageSubject(localId: asset.localId, remoteId: asset.remoteId, checksum: asset.checksum, type: asset.type);

  String get key => '${localId ?? ''}|${remoteId ?? ''}|${checksum ?? ''}';

  Map<String, dynamic> toJson() => {
    'id': localId ?? remoteId,
    'localId': localId,
    'remoteId': remoteId,
    'checksum': checksum,
    'type': ViewerPlugins.assetTypeName(type),
  };

  @override
  bool operator ==(Object other) =>
      other is ImageSubject &&
      other.localId == localId &&
      other.remoteId == remoteId &&
      other.checksum == checksum &&
      other.type == type;

  @override
  int get hashCode => Object.hash(localId, remoteId, checksum, type);
}

/// One image request that may go through the pipeline: which stage and which asset.
@immutable
class ImagePipelineTarget {
  final ImageStage stage;
  final ImageSubject subject;

  const ImagePipelineTarget(this.stage, this.subject);
}

/// A transformer built into the app (written in Dart), applied after the plugin hooks of a stage.
/// The viewer censor shield (`ViewerFilterV1`) is one.
abstract interface class ImageTransformer {
  /// Stable id; part of the cache key.
  String get id;

  /// Changes whenever the transformer's output for the same input would change (configuration, toggles).
  String get signature;

  bool appliesTo(ImageStage stage, ImageSubject subject);

  /// The transformed image, or null when the image stays as it is. Must not dispose [image].
  Future<ui.Image?> transform(ImageStage stage, ImageSubject subject, ui.Image image);
}

/// Resolves the AssetV1 JSON for a subject (bound by the kernel; default: the subject's ids).
typedef ImageSubjectJson = Future<Map<String, dynamic>> Function(ImageSubject subject);

/// Thrown when a plugin's `before` handler cancelled showing an image.
class ImageBlockedException implements Exception {
  final String? message;

  const ImageBlockedException([this.message]);

  @override
  String toString() => message ?? 'Image hidden by a plugin';
}

/// The generic image pipeline: `image.thumbnail`, `image.preview` and `image.full`.
///
/// Every decoded image of a stage passes through [apply] when a plugin hooks the stage or a built-in
/// [ImageTransformer] applies. Plugins receive the decoded pixels as an RGBA file and answer with a replacement
/// image (any size) or nothing ("unchanged"). Results are cached per stage, asset, decoded size and plugin versions,
/// in memory and on disk. With nothing hooked, [isActive] is false and image loading is untouched.
abstract final class ImagePipeline {
  static final _log = Logger('ImagePipeline');

  /// Bumped by [invalidate]. Widgets that show pipeline images re-resolve them when it changes.
  static final ValueNotifier<int> generation = ValueNotifier(0);

  /// Bound by the kernel (phase B) to build full AssetV1 JSON for plugins.
  static ImageSubjectJson? subjectJson;

  static final List<ImageTransformer> _transformers = [];

  static const _maxConcurrent = 3;
  static const _maxMemoryEntries = 512;
  static const _maxDiskEntries = 1500;

  static final _memory = <String, _CacheEntry>{};
  static final _inFlight = <String, Future<void>>{};
  static final _waiting = Queue<Completer<void>>();
  static int _running = 0;
  static int _writes = 0;
  static Future<Directory>? _root;

  static List<ImageTransformer> get transformers => List.unmodifiable(_transformers);

  static void addTransformer(ImageTransformer transformer) {
    _transformers
      ..removeWhere((t) => t.id == transformer.id)
      ..add(transformer);
    invalidate();
  }

  static void removeTransformer(String id) {
    final before = _transformers.length;
    _transformers.removeWhere((t) => t.id == id);
    if (_transformers.length != before) {
      invalidate();
    }
  }

  /// Whether images of [stage] go through the pipeline at all. Cheap; call it before any pipeline work.
  static bool isActive(ImageStage stage) =>
      PluginHooks.has(stage.hookId) || (_transformers.isNotEmpty && _transformers.any((t) => _stageOf(t, stage)));

  /// Whether [target] goes through the pipeline.
  static bool isActiveFor(ImagePipelineTarget target) =>
      PluginHooks.has(target.stage.hookId) || _transformers.any((t) => t.appliesTo(target.stage, target.subject));

  static bool _stageOf(ImageTransformer transformer, ImageStage stage) => transformer.appliesTo(
    stage,
    const ImageSubject(type: AssetType.image),
  );

  /// Drops every cached result and every decoded image so the next request runs the pipeline again.
  /// The kernel calls this when plugins change; plugins call it through `image.invalidate`.
  static void invalidate({String? assetId}) {
    if (assetId == null) {
      _memory.clear();
      unawaited(_clearDisk());
    } else {
      _memory.removeWhere((key, entry) => entry.subjectKey.contains(assetId));
    }
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    generation.value++;
    PluginHooks.emit(ViewerEventNames.imageInvalidated, () => {'assetId': assetId});
  }

  /// The image to show for [target] instead of [info], or [info] itself when nothing changes it.
  ///
  /// Throws [ImageBlockedException] when a plugin cancelled showing the image. Takes ownership of [info]: it is
  /// returned as is, or disposed when a replacement is returned.
  static Future<ImageInfo> apply(ImagePipelineTarget target, ImageInfo info) async {
    final outcome = await _outcome(target, info.image);
    switch (outcome) {
      case _Unchanged():
        return info;
      case _Blocked(:final message):
        info.dispose();
        throw ImageBlockedException(message);
      case _Replaced(:final image):
        final scale = info.scale;
        info.dispose();
        return ImageInfo(image: image, scale: scale);
    }
  }

  /// [apply] for a raw [ui.Image]; returns null when unchanged. Does not dispose [image].
  static Future<ui.Image?> applyToImage(ImagePipelineTarget target, ui.Image image) async {
    final outcome = await _outcome(target, image);
    return switch (outcome) {
      _Unchanged() => null,
      _Blocked(:final message) => throw ImageBlockedException(message),
      _Replaced(:final image) => image,
    };
  }

  /// What the user sees while a hooked stage is pending: the lower-resolution image [info] as is when the
  /// thumbnail stage itself is processed (it already went through the pipeline), otherwise blurred so an
  /// unprocessed image is never shown sharp. Returns [info] untouched when [pending] is not active.
  static ImageInfo? placeholder(ImageInfo? info, ImageStage pending) {
    if (info == null || !isActive(pending) || isActive(ImageStage.thumbnail)) {
      return info;
    }
    try {
      return blurred(info);
    } catch (error, stack) {
      _log.warning('Could not blur placeholder', error, stack);
      return info;
    }
  }

  /// A blurred copy of [info] (synchronous; disposes [info]).
  static ImageInfo blurred(ImageInfo info) {
    final image = info.image;
    final sigma = math.max(4.0, math.max(image.width, image.height) / 24);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImage(
      image,
      ui.Offset.zero,
      ui.Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: ui.TileMode.mirror),
    );
    final picture = recorder.endRecording();
    try {
      final result = ImageInfo(image: picture.toImageSync(image.width, image.height), scale: info.scale);
      info.dispose();
      return result;
    } finally {
      picture.dispose();
    }
  }

  static Future<_Outcome> _outcome(ImagePipelineTarget target, ui.Image image) {
    final hooked = PluginHooks.has(target.stage.hookId);
    final transformers = [
      for (final transformer in _transformers)
        if (transformer.appliesTo(target.stage, target.subject)) transformer,
    ];
    if (!hooked && transformers.isEmpty) {
      return Future.value(const _Unchanged());
    }

    final signature = [
      if (hooked) ViewerPlugins.hookSignature(target.stage.hookId),
      for (final transformer in transformers) '${transformer.id}@${transformer.signature}',
    ].join(';');
    final key = sha1
        .convert(utf8.encode('${target.stage.name}|${target.subject.key}|${image.width}x${image.height}|$signature'))
        .toString();

    final running = _inFlight[key];
    if (running != null) {
      // The first request owns its image; later ones read the stored result (a handle of their own).
      return running.then((_) => _cached(key)).then((cached) => cached ?? _compute(key, target, image, hooked, transformers));
    }
    final future = _compute(key, target, image, hooked, transformers);
    _inFlight[key] = future.then<void>((_) {}, onError: (_) {}).whenComplete(() => _inFlight.remove(key));
    return future;
  }

  static Future<_Outcome> _compute(
    String key,
    ImagePipelineTarget target,
    ui.Image image,
    bool hooked,
    List<ImageTransformer> transformers,
  ) async {
    final cached = await _cached(key);
    if (cached != null) {
      return cached;
    }

    await _acquire();
    try {
      ui.Image? current;
      if (hooked) {
        final result = await _runHook(target, image);
        if (result is _Blocked) {
          _remember(key, _CacheEntry.blocked(target.subject.key, result.message));
          return result;
        }
        if (result is _Replaced) {
          current = result.image;
        }
      }
      for (final transformer in transformers) {
        try {
          final next = await transformer.transform(target.stage, target.subject, current ?? image);
          if (next != null) {
            current?.dispose();
            current = next;
          }
        } catch (error, stack) {
          _log.warning('Image transformer ${transformer.id} failed', error, stack);
        }
      }

      if (current == null) {
        _remember(key, _CacheEntry.unchanged(target.subject.key));
        return const _Unchanged();
      }
      await _store(key, target.subject.key, current);
      return _Replaced(current);
    } finally {
      _release();
    }
  }

  static Future<_Outcome> _runHook(ImagePipelineTarget target, ui.Image image) async {
    final source = await _writeRgba(image, 'src');
    if (source == null) {
      return const _Unchanged();
    }
    final asset = await (subjectJson?.call(target.subject) ?? Future.value(target.subject.toJson()));
    try {
      final result = await PluginHooks.run<Map<String, dynamic>?>(
        target.stage.hookId,
        () => {
          'stage': target.stage.name,
          'asset': asset,
          'size': {'width': image.width, 'height': image.height},
          'source': {'path': source.path, 'width': image.width, 'height': image.height, 'format': 'rgba'},
        },
        () async => null,
        encode: (value) => value,
        decode: (json) => json is Map ? Map<String, dynamic>.from(json) : null,
      );
      if (result == null || result['unchanged'] == true) {
        return const _Unchanged();
      }
      if (result['blocked'] == true) {
        return _Blocked(result['message'] as String?);
      }
      final decoded = await decodeImageResult(result);
      return decoded == null ? const _Unchanged() : _Replaced(decoded);
    } catch (error, stack) {
      if (PluginHooks.isCancelled(error)) {
        return _Blocked(PluginHooks.cancelMessage(error));
      }
      _log.warning('${target.stage.hookId} failed; showing the original', error, stack);
      return const _Unchanged();
    } finally {
      unawaited(_deleteQuietly(source));
    }
  }

  /// Decodes an image a plugin returned:
  /// `{ "path", "width", "height", "format": "rgba" }`, `{ "path", "format": "encoded" }` (PNG, JPEG, WebP, ...),
  /// `{ "rgba": base64, "width", "height" }` or `{ "encoded": base64 }`.
  static Future<ui.Image?> decodeImageResult(Map<String, dynamic> result) async {
    final width = (result['width'] as num?)?.toInt();
    final height = (result['height'] as num?)?.toInt();
    final path = result['path'];
    final format = '${result['format'] ?? (result['rgba'] != null ? 'rgba' : 'encoded')}';

    Uint8List? bytes;
    if (path is String && path.isNotEmpty) {
      bytes = await File(path).readAsBytes();
    } else if (result['rgba'] is String) {
      bytes = base64Decode(result['rgba'] as String);
    } else if (result['encoded'] is String) {
      bytes = base64Decode(result['encoded'] as String);
    }
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    if (format == 'rgba') {
      if (width == null || height == null || width <= 0 || height <= 0) {
        return null;
      }
      return decodeRgba(bytes, width, height);
    }
    return decodeEncoded(bytes);
  }

  static Future<ui.Image> decodeRgba(Uint8List bytes, int width, int height) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    return _firstFrame(buffer, descriptor);
  }

  static Future<ui.Image> decodeEncoded(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    return _firstFrame(buffer, descriptor);
  }

  static Future<ui.Image> _firstFrame(ui.ImmutableBuffer buffer, ui.ImageDescriptor descriptor) async {
    final codec = await descriptor.instantiateCodec();
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  /// A one-frame codec for [image] (used where an animated codec is expected).
  static Future<ui.Codec> codecOf(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('Could not read image pixels');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: image.width,
      height: image.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    buffer.dispose();
    return descriptor.instantiateCodec();
  }

  /// Writes the raw RGBA pixels of [image] to a new file in the pipeline's folder.
  static Future<File?> writeRgba(ui.Image image, {String prefix = 'img'}) => _writeRgba(image, prefix);

  static Future<File?> _writeRgba(ui.Image image, String prefix) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      return null;
    }
    final dir = Directory(p.join((await _directory()).path, 'tmp'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, '$prefix-${DateTime.now().microsecondsSinceEpoch}-${image.hashCode}.rgba'));
    await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    return file;
  }

  static Future<Directory> _directory() => _root ??= () async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'image_pipeline'));
    await dir.create(recursive: true);
    return dir;
  }();

  static Future<_Outcome?> _cached(String key) async {
    final entry = _memory.remove(key);
    if (entry != null) {
      _memory[key] = entry;
      switch (entry.kind) {
        case _CacheKind.unchanged:
          return const _Unchanged();
        case _CacheKind.blocked:
          return _Blocked(entry.message);
        case _CacheKind.replaced:
          break;
      }
    }
    try {
      final dir = await _directory();
      final meta = File(p.join(dir.path, 'cache', '$key.json'));
      final pixels = File(p.join(dir.path, 'cache', '$key.rgba'));
      // ignore: avoid_slow_async_io
      if (!await meta.exists() || !await pixels.exists()) {
        _memory.remove(key);
        return null;
      }
      final json = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      final image = await decodeRgba(await pixels.readAsBytes(), json['width'] as int, json['height'] as int);
      _remember(key, _CacheEntry.replaced('${json['subject']}'));
      return _Replaced(image);
    } catch (error) {
      _memory.remove(key);
      return null;
    }
  }

  static Future<void> _store(String key, String subjectKey, ui.Image image) async {
    _remember(key, _CacheEntry.replaced(subjectKey));
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        return;
      }
      final dir = Directory(p.join((await _directory()).path, 'cache'));
      await dir.create(recursive: true);
      await File(
        p.join(dir.path, '$key.rgba'),
      ).writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      await File(
        p.join(dir.path, '$key.json'),
      ).writeAsString(jsonEncode({'width': image.width, 'height': image.height, 'subject': subjectKey}));
      if (++_writes % 50 == 0) {
        unawaited(_trimDisk(dir));
      }
    } catch (error, stack) {
      _log.fine('Could not cache pipeline result', error, stack);
    }
  }

  static void _remember(String key, _CacheEntry entry) {
    _memory.remove(key);
    _memory[key] = entry;
    while (_memory.length > _maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  static Future<void> _trimDisk(Directory dir) async {
    final files = await dir.list().where((e) => e is File && e.path.endsWith('.rgba')).cast<File>().toList();
    if (files.length <= _maxDiskEntries) {
      return;
    }
    final stats = [for (final file in files) (file, file.statSync().modified)]..sort((a, b) => a.$2.compareTo(b.$2));
    for (final (file, _) in stats.take(files.length - _maxDiskEntries)) {
      await _deleteQuietly(file);
      await _deleteQuietly(File(file.path.replaceFirst(RegExp(r'\.rgba$'), '.json')));
    }
  }

  static Future<void> _clearDisk() async {
    try {
      final dir = Directory(p.join((await _directory()).path, 'cache'));
      // ignore: avoid_slow_async_io
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Best effort; stale entries have other keys after a plugin change anyway.
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Already gone.
    }
  }

  static Future<void> _acquire() async {
    if (_running < _maxConcurrent) {
      _running++;
      return;
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    await waiter.future;
  }

  static void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
      return;
    }
    _running--;
  }
}

enum _CacheKind { unchanged, replaced, blocked }

class _CacheEntry {
  final _CacheKind kind;
  final String subjectKey;
  final String? message;

  const _CacheEntry.unchanged(this.subjectKey) : kind = _CacheKind.unchanged, message = null;

  const _CacheEntry.replaced(this.subjectKey) : kind = _CacheKind.replaced, message = null;

  const _CacheEntry.blocked(this.subjectKey, this.message) : kind = _CacheKind.blocked;
}

sealed class _Outcome {
  const _Outcome();
}

class _Unchanged extends _Outcome {
  const _Unchanged();
}

class _Blocked extends _Outcome {
  final String? message;

  const _Blocked(this.message);
}

class _Replaced extends _Outcome {
  final ui.Image image;

  const _Replaced(this.image);
}
