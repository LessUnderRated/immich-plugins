import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/gallery_view.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';

/// Hook that lets plugins filter, sort and group what a timeline shows.
const timelineQueryHookId = 'timeline.query';

/// Event emitted when a timeline finished loading a new set of buckets.
const timelineReloadedEventId = 'timeline.reloaded';

/// The compact, synchronous AssetV1 subset the timeline hands to plugins (hook args, slot contexts, host results).
///
/// Keys follow AssetV1 (`id`, `type`, `originalFileName`, `fileCreatedAt`, `isFavorite`, ...) and add the timeline's
/// own (`localId`, `remoteId`, `storage`, `isLocal`, `isRemote`, `width`, `height`, `durationMs`). Plugins that need
/// the full AssetV1 (EXIF, tags, paths) ask for it with the `assets.get` host function.
abstract final class TimelineAssetJson {
  static String typeName(AssetType type) => switch (type) {
    AssetType.image => 'IMAGE',
    AssetType.video => 'VIDEO',
    AssetType.audio => 'AUDIO',
    AssetType.other => 'OTHER',
  };

  static Map<String, dynamic> encode(BaseAsset asset) {
    final json = <String, dynamic>{
      'id': asset.id,
      'localId': asset.localId,
      'remoteId': asset.remoteId,
      'type': typeName(asset.type),
      'originalFileName': asset.name,
      'checksum': asset.checksum,
      'fileCreatedAt': asset.createdAt.toUtc().toIso8601String(),
      'fileModifiedAt': asset.updatedAt.toUtc().toIso8601String(),
      'localDateTime': asset.createdAt.toLocal().toIso8601String(),
      'width': asset.width,
      'height': asset.height,
      'durationMs': asset.durationMs,
      'isFavorite': asset.isFavorite,
      'isEdited': asset.isEdited,
      'storage': asset.storage.name,
      'isLocal': asset.hasLocal,
      'isRemote': asset.hasRemote,
      'playbackStyle': asset.playbackStyle.name,
    };
    switch (asset) {
      case final RemoteAsset remote:
        json['ownerId'] = remote.ownerId;
        json['visibility'] = remote.visibility.name;
        json['stackId'] = remote.stackId;
        json['livePhotoVideoId'] = remote.livePhotoVideoId;
        json['deletedAt'] = remote.deletedAt?.toUtc().toIso8601String();
        json['isTrashed'] = remote.isTrashed;
        json['isArchived'] = remote.isArchived;
      case final LocalAsset local:
        json['latitude'] = local.latitude;
        json['longitude'] = local.longitude;
        json['orientation'] = local.orientation;
    }
    return json;
  }

  static List<Map<String, dynamic>> encodeAll(Iterable<BaseAsset> assets) => [for (final asset in assets) encode(asset)];

  /// Whether [asset] is the one a plugin names with [id] (its id, local id or remote id).
  static bool matches(BaseAsset asset, String id) => asset.id == id || asset.localId == id || asset.remoteId == id;
}

/// A group of a timeline that a `timeline.query` plugin made. It is a [TimeBucket] (so date jumps and the scrubber
/// keep working) with its own header [title], [subtitle] and scrubber [label].
class PluginGroupBucket extends TimeBucket {
  final String? title;
  final String? subtitle;
  final String? label;

  /// Large (month style) header instead of a small (day style) one.
  final bool large;

  const PluginGroupBucket({
    required super.date,
    required super.assetCount,
    this.title,
    this.subtitle,
    this.label,
    this.large = false,
  });

  bool get hasHeader => title != null || subtitle != null;

  Map<String, dynamic> toJson() => {
    'title': title,
    'subtitle': subtitle,
    'label': label,
    'large': large,
    'date': date.toUtc().toIso8601String(),
    'count': assetCount,
  };

  @override
  bool operator ==(covariant TimeBucket other) {
    return other is PluginGroupBucket &&
        super == other &&
        title == other.title &&
        subtitle == other.subtitle &&
        label == other.label &&
        large == other.large;
  }

  @override
  int get hashCode => Object.hash(super.hashCode, title, subtitle, label, large);
}

/// What a timeline shows: its assets in order and the buckets (groups) they fall into.
class TimelineQueryResult {
  final List<BaseAsset> assets;
  final List<Bucket> buckets;

  const TimelineQueryResult({required this.assets, required this.buckets});
}

/// JSON shapes of the `timeline.query` hook.
///
/// args: `{ "origin", "groupBy": "day|month|none", "total", "galleryView"? }`; a `before` handler may change
/// `groupBy`. result: `{ "assets": [asset], "groups": [{ "title"?, "subtitle"?, "label"?, "date"?, "large"?, "count" }] }`.
/// A plugin answers with `assets` as a list of assets or ids (a subset filters, another order sorts; unknown ids are
/// dropped) and optionally `groups` whose counts add up to the number of assets; without valid groups the app groups
/// the result by [groupBy] itself.
abstract final class TimelineQueryCodec {
  static String groupByName(GroupAssetsBy? groupBy) => switch (groupBy) {
    GroupAssetsBy.day || GroupAssetsBy.auto => 'day',
    GroupAssetsBy.month => 'month',
    GroupAssetsBy.none || null => 'none',
  };

  static GroupAssetsBy? parseGroupBy(Object? value) => switch (value) {
    'day' => GroupAssetsBy.day,
    'month' => GroupAssetsBy.month,
    'none' => GroupAssetsBy.none,
    _ => null,
  };

  static Map<String, dynamic> galleryViewJson(GalleryViewSpec spec) => {
    'sort': {'field': spec.sortField.name, 'direction': spec.descending ? 'desc' : 'asc'},
    'include': {'photos': spec.photos, 'videos': spec.videos, 'gifs': spec.gifs},
    'excludeAlbumIds': spec.excludeAlbumIds.toList(),
  };

  static Object? encode(TimelineQueryResult result) => {
    'assets': TimelineAssetJson.encodeAll(result.assets),
    'groups': [
      for (final bucket in result.buckets)
        if (bucket is PluginGroupBucket)
          bucket.toJson()
        else if (bucket is TimeBucket)
          {'date': bucket.date.toUtc().toIso8601String(), 'count': bucket.assetCount}
        else
          {'count': bucket.assetCount},
    ],
  };

  /// Maps a plugin's answer back onto [original]'s assets; groups the result with [groupBy] when the plugin gave no
  /// valid groups.
  static TimelineQueryResult decode(Object? json, TimelineQueryResult original, GroupAssetsBy? groupBy) {
    if (json is! Map) {
      return original;
    }
    final assets = _decodeAssets(json['assets'], original.assets);
    final groups = _decodeGroups(json['groups'], assets);
    return TimelineQueryResult(assets: assets, buckets: groups ?? group(assets, groupBy));
  }

  static List<BaseAsset> _decodeAssets(Object? json, List<BaseAsset> original) {
    if (json is! List) {
      return original;
    }
    final byId = <String, BaseAsset>{};
    for (final asset in original) {
      byId.putIfAbsent(asset.id, () => asset);
      if (asset.localId case final localId?) {
        byId.putIfAbsent(localId, () => asset);
      }
      if (asset.remoteId case final remoteId?) {
        byId.putIfAbsent(remoteId, () => asset);
      }
    }
    final seen = <BaseAsset>{};
    final result = <BaseAsset>[];
    for (final entry in json) {
      final id = switch (entry) {
        final String id => id,
        final num id => '$id',
        final Map map => map['id'] == null ? null : '${map['id']}',
        _ => null,
      };
      final asset = id == null ? null : byId[id];
      if (asset != null && seen.add(asset)) {
        result.add(asset);
      }
    }
    return result;
  }

  static List<Bucket>? _decodeGroups(Object? json, List<BaseAsset> assets) {
    if (json is! List || json.isEmpty) {
      return null;
    }
    final buckets = <Bucket>[];
    var offset = 0;
    for (final entry in json) {
      if (entry is! Map) {
        return null;
      }
      final count = entry['count'];
      if (count is! num || count <= 0 || offset + count.toInt() > assets.length) {
        return null;
      }
      final date = entry['date'] is String ? DateTime.tryParse(entry['date'] as String) : null;
      buckets.add(
        PluginGroupBucket(
          date: (date ?? assets[offset].createdAt).toLocal(),
          assetCount: count.toInt(),
          title: entry['title'] is String ? entry['title'] as String : null,
          subtitle: entry['subtitle'] is String ? entry['subtitle'] as String : null,
          label: entry['label'] is String ? entry['label'] as String : null,
          large: entry['large'] == true,
        ),
      );
      offset += count.toInt();
    }
    return offset == assets.length ? buckets : null;
  }

  /// Groups [assets] (in their order) the way the app groups a timeline: consecutive assets of the same local day or
  /// month form a bucket; [GroupAssetsBy.none] makes one bucket.
  static List<Bucket> group(List<BaseAsset> assets, GroupAssetsBy? groupBy) {
    if (assets.isEmpty) {
      return const [];
    }
    if (groupBy == null || groupBy == GroupAssetsBy.none) {
      return [Bucket(assetCount: assets.length)];
    }
    final byMonth = groupBy == GroupAssetsBy.month;
    DateTime keyOf(BaseAsset asset) {
      final local = asset.createdAt.toLocal();
      return byMonth ? DateTime(local.year, local.month) : DateTime(local.year, local.month, local.day);
    }

    final buckets = <Bucket>[];
    var current = keyOf(assets.first);
    var count = 0;
    for (final asset in assets) {
      final key = keyOf(asset);
      if (key != current) {
        buckets.add(TimeBucket(date: current, assetCount: count));
        current = key;
        count = 0;
      }
      count++;
    }
    buckets.add(TimeBucket(date: current, assetCount: count));
    return buckets;
  }

  /// The grouping the buckets of a timeline imply when the caller did not say: none for plain buckets, month when
  /// every bucket starts on the first of a month, day otherwise.
  static GroupAssetsBy inferGroupBy(List<Bucket> buckets) {
    if (buckets.isEmpty || buckets.any((bucket) => bucket is! TimeBucket)) {
      return GroupAssetsBy.none;
    }
    final dates = buckets.cast<TimeBucket>().map((bucket) => bucket.date);
    final monthly = buckets.length > 1 && dates.every((date) => date.day == 1);
    return monthly ? GroupAssetsBy.month : GroupAssetsBy.day;
  }
}
