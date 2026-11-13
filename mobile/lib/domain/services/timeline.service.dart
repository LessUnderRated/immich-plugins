import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/gallery_view.model.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_plugin.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:immich_mobile/utils/async_mutex.dart';

typedef TimelineAssetSource = Future<List<BaseAsset>> Function(int index, int count);

typedef TimelineBucketSource = Stream<List<Bucket>> Function();

typedef TimelineQuery = ({TimelineAssetSource assetSource, TimelineBucketSource bucketSource, TimelineOrigin origin});

enum TimelineOrigin {
  main,
  localAlbum,
  remoteAlbum,
  remoteAssets,
  favorite,
  trash,
  archive,
  lockedFolder,
  video,
  place,
  person,
  map,
  search,
  deepLink,
  albumActivities,
  folder,
  recentlyAdded,
}

class TimelineFactory {
  final TimelineRepository _timelineRepository;
  final SettingsRepository _settingsRepository;

  const TimelineFactory({required this._timelineRepository, required this._settingsRepository});

  GroupAssetsBy get groupBy {
    final group = _settingsRepository.appConfig.timeline.groupAssetsBy;
    // We do not support auto grouping in the new timeline yet, fallback to day grouping
    return group == GroupAssetsBy.auto ? GroupAssetsBy.day : group;
  }

  TimelineService main(List<String> timelineUsers) =>
      TimelineService(_timelineRepository.main(timelineUsers, groupBy), groupBy: groupBy);

  TimelineService deviceLibrary({GalleryViewSpec? view, Set<String> hiddenIds = const {}}) => TimelineService(
    _timelineRepository.deviceLibrary(GroupAssetsBy.none, view: view, hiddenIds: hiddenIds),
    groupBy: GroupAssetsBy.none,
    hookArgs: _galleryViewArgs(view),
  );

  TimelineService privateAlbum(Set<String> assetIds) =>
      TimelineService(_timelineRepository.privateAlbum(assetIds), groupBy: GroupAssetsBy.none);

  TimelineService localAlbum({required String albumId, GalleryViewSpec? view, Set<String> hiddenIds = const {}}) =>
      TimelineService(
        _timelineRepository.localAlbum(albumId, GroupAssetsBy.none, view: view, hiddenIds: hiddenIds),
        groupBy: GroupAssetsBy.none,
        hookArgs: {'albumId': albumId, ..._galleryViewArgs(view)},
      );

  TimelineService appAlbum(List<String> assetIds, {GalleryViewSpec? view, Set<String> hiddenIds = const {}}) =>
      TimelineService(
        _timelineRepository.appAlbum(assetIds, view: view, hiddenIds: hiddenIds),
        hookArgs: _galleryViewArgs(view),
      );

  TimelineService remoteAlbum({required String albumId}) => TimelineService(
    _timelineRepository.remoteAlbum(albumId, groupBy),
    groupBy: groupBy,
    hookArgs: {'albumId': albumId},
  );

  TimelineService remoteAssets(String userId) =>
      TimelineService(_timelineRepository.remote(userId, groupBy), groupBy: groupBy);

  TimelineService recentlyAdded(String userId) =>
      TimelineService(_timelineRepository.recentlyAdded(userId, groupBy), groupBy: groupBy);

  TimelineService favorite(String userId) =>
      TimelineService(_timelineRepository.favorite(userId, groupBy), groupBy: groupBy);

  TimelineService trash(String userId) => TimelineService(_timelineRepository.trash(userId, groupBy), groupBy: groupBy);

  TimelineService archive(String userId) =>
      TimelineService(_timelineRepository.archived(userId, groupBy), groupBy: groupBy);

  TimelineService lockedFolder(String userId) =>
      TimelineService(_timelineRepository.locked(userId, groupBy), groupBy: groupBy);

  TimelineService video(String userId) => TimelineService(_timelineRepository.video(userId, groupBy), groupBy: groupBy);

  TimelineService place(String place) =>
      TimelineService(_timelineRepository.place(place, groupBy), groupBy: groupBy, hookArgs: {'place': place});

  TimelineService person(String userId, String personId) => TimelineService(
    _timelineRepository.person(userId, personId, groupBy),
    groupBy: groupBy,
    hookArgs: {'personId': personId},
  );

  TimelineService fromAssets(List<BaseAsset> assets, TimelineOrigin type) =>
      TimelineService(_timelineRepository.fromAssets(assets, type));

  TimelineService fromAssetStream(List<BaseAsset> Function() getAssets, Stream<int> assetCount, TimelineOrigin type) =>
      TimelineService(_timelineRepository.fromAssetStream(getAssets, assetCount, type));

  TimelineService fromAssetsWithBuckets(List<BaseAsset> assets, TimelineOrigin type) =>
      TimelineService(_timelineRepository.fromAssetsWithBuckets(assets, type));

  /// Creates a TimelineService for serving geographical map queries, such assets within bounded locations
  TimelineService geographicMap(
    List<String> userIds,
    TimelineMapOptions Function() currentOptions,
    Stream<TimelineMapOptions> optionsStream,
  ) => TimelineService(
    _timelineRepository.geographicMap(userIds, currentOptions, optionsStream, groupBy),
    groupBy: groupBy,
  );

  static Map<String, dynamic> _galleryViewArgs(GalleryViewSpec? view) =>
      view == null ? const {} : {'galleryView': TimelineQueryCodec.galleryViewJson(view)};
}

class TimelineService {
  final TimelineAssetSource _assetSource;
  final TimelineBucketSource _bucketSource;
  final TimelineOrigin origin;
  final _PluginTimelineQuery? _plugin;
  final AsyncMutex _mutex = AsyncMutex();
  int _bufferOffset = 0;
  List<BaseAsset> _buffer = [];
  StreamSubscription? _bucketSubscription;

  int _totalAssets = 0;
  int get totalAssets => _totalAssets;

  /// [groupBy] is how [query] groups its buckets and [hookArgs] are extra arguments of the `timeline.query` hook
  /// (album id, gallery view, ...). When a plugin hooks `timeline.query`, the query runs through it so the plugin can
  /// filter, sort and group what this timeline shows; otherwise [query] is used as is.
  TimelineService(TimelineQuery query, {GroupAssetsBy? groupBy, Map<String, dynamic> hookArgs = const {}})
    : this._hooked(_PluginTimelineQuery.attach(query, groupBy: groupBy, hookArgs: hookArgs), query);

  TimelineService._hooked(_PluginTimelineQuery? plugin, TimelineQuery query)
    : this._(
        assetSource: plugin?.assetSource ?? query.assetSource,
        bucketSource: plugin?.bucketSource ?? query.bucketSource,
        origin: query.origin,
        plugin: plugin,
      );

  TimelineService._({
    required this._assetSource,
    required this._bucketSource,
    required this.origin,
    this._plugin,
  }) {
    _bucketSubscription = _bucketSource().listen((buckets) {
      unawaited(
        _mutex.run(() async {
          final totalAssets = buckets.fold<int>(0, (acc, bucket) => acc + bucket.assetCount);

          if (totalAssets == 0) {
            _bufferOffset = 0;
            _buffer = [];
          } else {
            final int offset;
            final int count;
            // When the buffer is empty or the old bufferOffset is greater than the new total assets,
            // we need to reset the buffer and load the first batch of assets.
            if (_bufferOffset >= totalAssets || _buffer.isEmpty) {
              offset = 0;
              count = kTimelineAssetLoadBatchSize;
            } else {
              offset = _bufferOffset;
              count = math.min(_buffer.length, totalAssets - _bufferOffset);
            }
            _buffer = await _assetSource(offset, count);
            _bufferOffset = offset;
          }

          // change the state's total assets count only after the buffer is reloaded
          _totalAssets = totalAssets;
          EventStream.shared.emit(const TimelineReloadEvent());
          PluginHooks.emit(timelineReloadedEventId, () => {'origin': origin.name, 'total': totalAssets});
        }),
      );
    });
  }

  Stream<List<Bucket>> Function() get watchBuckets => _bucketSource;

  /// Whether a `timeline.query` plugin shapes what this timeline shows.
  bool get isPluginQuery => _plugin != null;

  /// Runs the `timeline.query` hook again (a plugin changed its filter) and reloads the timeline.
  Future<void> refresh() async {
    await _plugin?.rerun();
    EventStream.shared.emit(const TimelineReloadEvent());
  }

  Future<List<BaseAsset>> loadAssets(int index, int count) => _mutex.run(() => _loadAssets(index, count));

  Future<List<BaseAsset>> _loadAssets(int index, int count) async {
    if (hasRange(index, count)) {
      return getAssets(index, count);
    }

    // if the requested offset is greater than the cached offset, the user scrolls forward "down"
    final bool forward = _bufferOffset < index;

    // make sure to load a meaningful amount of data (and not only the requested slice)
    // otherwise, each call to [loadAssets] would result in DB call trashing performance
    // fills small requests to [kTimelineAssetLoadBatchSize], adds some legroom into the opposite scroll direction for large requests
    final len = math.max(kTimelineAssetLoadBatchSize, count + kTimelineAssetLoadOppositeSize);
    // when scrolling forward, start shortly before the requested offset
    // when scrolling backward, end shortly after the requested offset to guard against the user scrolling
    // in the other direction a tiny bit resulting in another required load from the DB
    final start = math.max(
      0,
      forward
          ? index - kTimelineAssetLoadOppositeSize
          : (len > kTimelineAssetLoadBatchSize ? index : index + count - len),
    );

    _buffer = await _assetSource(start, len);
    _bufferOffset = start;

    return getAssets(index, count);
  }

  bool hasRange(int index, int count) =>
      index >= 0 &&
      index < _totalAssets &&
      index >= _bufferOffset &&
      index + count <= _bufferOffset + _buffer.length &&
      index + count <= _totalAssets;

  List<BaseAsset> getAssets(int index, int count) {
    if (!hasRange(index, count)) {
      throw RangeError('TimelineService::getAssets Index out of range');
    }
    final int start = index - _bufferOffset;
    return _buffer.slice(start, start + count);
  }

  // Preload assets around the given index for asset viewer
  Future<void> preloadAssets(int index) => _mutex.run(() => _loadAssets(index, math.min(5, _totalAssets - index)));

  BaseAsset getRandomAsset() => _buffer.elementAt(math.Random().nextInt(_buffer.length));

  /// Gets an asset at the given index, automatically loading the buffer if needed.
  /// This is an async version that can handle out-of-range indices by loading the appropriate buffer.
  Future<BaseAsset?> getAssetAsync(int index) async {
    if (index < 0 || index >= _totalAssets) {
      return null;
    }

    if (hasRange(index, 1)) {
      return _buffer.elementAt(index - _bufferOffset);
    }

    // Load the buffer containing the requested index
    try {
      final assets = await loadAssets(index, 1);
      return assets.isNotEmpty ? assets.first : null;
    } catch (e) {
      return null;
    }
  }

  /// Safely gets an asset at the given index without throwing a RangeError.
  /// Returns null if the index is out of bounds or not currently in the buffer.
  /// For automatic buffer loading, use getAssetAsync instead.
  BaseAsset? getAssetSafe(int index) {
    if (index < 0 || index >= _totalAssets || !hasRange(index, 1)) {
      return null;
    }
    return _buffer.elementAt(index - _bufferOffset);
  }

  /// Finds the index of an asset by its heroTag within the current buffer.
  /// Returns null if the asset is not found in the buffer.
  int? getIndex(String heroTag) {
    final index = _buffer.indexWhere((a) => a.heroTag == heroTag);
    return index >= 0 ? _bufferOffset + index : null;
  }

  Future<void> dispose() async {
    await _bucketSubscription?.cancel();
    _bucketSubscription = null;
    await _plugin?.dispose();
    _buffer = [];
    _bufferOffset = 0;
  }
}

/// A timeline query run through the `timeline.query` hook.
///
/// It loads every asset of the source query whenever the source buckets change, lets plugins filter, sort and group
/// them, and serves the result: buckets from the plugin's groups (or grouped like the source) and assets by index.
/// Only used while a plugin hooks `timeline.query`.
class _PluginTimelineQuery {
  final TimelineQuery _source;
  final GroupAssetsBy? _groupBy;
  final Map<String, dynamic> _hookArgs;
  final StreamController<List<Bucket>> _updates = StreamController.broadcast();
  final AsyncMutex _mutex = AsyncMutex();
  StreamSubscription<List<Bucket>>? _subscription;
  List<Bucket>? _sourceBuckets;
  List<Bucket>? _latest;
  List<BaseAsset> _assets = const [];

  _PluginTimelineQuery._(this._source, this._groupBy, this._hookArgs);

  static _PluginTimelineQuery? attach(
    TimelineQuery query, {
    GroupAssetsBy? groupBy,
    Map<String, dynamic> hookArgs = const {},
  }) => PluginHooks.has(timelineQueryHookId) ? _PluginTimelineQuery._(query, groupBy, hookArgs) : null;

  Future<List<BaseAsset>> assetSource(int index, int count) async {
    final end = math.min(_assets.length, index + count);
    return index >= end ? const [] : _assets.sublist(index, end);
  }

  Stream<List<Bucket>> bucketSource() {
    _subscription ??= _source.bucketSource().listen(
      (buckets) => unawaited(_mutex.run(() => _apply(buckets))),
      onError: _updates.addError,
    );
    return Stream.multi((controller) {
      final latest = _latest;
      if (latest != null) {
        controller.add(latest);
      }
      final subscription = _updates.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = subscription.cancel;
    });
  }

  Future<void> rerun() async {
    final buckets = _sourceBuckets;
    if (buckets != null) {
      await _mutex.run(() => _apply(buckets));
    }
  }

  Future<void> _apply(List<Bucket> buckets) async {
    if (_updates.isClosed) {
      return;
    }
    _sourceBuckets = buckets;
    final total = buckets.fold<int>(0, (sum, bucket) => sum + bucket.assetCount);
    final assets = total == 0 ? const <BaseAsset>[] : await _source.assetSource(0, total);
    var groupBy = _groupBy ?? TimelineQueryCodec.inferGroupBy(buckets);
    final original = TimelineQueryResult(assets: assets, buckets: buckets);

    TimelineQueryResult result;
    try {
      result = await PluginHooks.run<TimelineQueryResult>(
        timelineQueryHookId,
        () => {
          'origin': _source.origin.name,
          'groupBy': TimelineQueryCodec.groupByName(groupBy),
          'total': total,
          ..._hookArgs,
        },
        () async => original,
        withArgs: (args) async {
          final regroup = TimelineQueryCodec.parseGroupBy(args['groupBy']);
          if (regroup == null || regroup == groupBy) {
            return original;
          }
          groupBy = regroup;
          return TimelineQueryResult(assets: assets, buckets: TimelineQueryCodec.group(assets, regroup));
        },
        encode: TimelineQueryCodec.encode,
        decode: (json) => TimelineQueryCodec.decode(json, original, groupBy),
      );
    } catch (_) {
      // A cancelled or failed plugin never hides the timeline: show it unchanged.
      result = original;
    }

    if (_updates.isClosed) {
      return;
    }
    _assets = result.assets;
    _latest = result.buckets;
    _updates.add(result.buckets);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _updates.close();
    _assets = const [];
  }
}
