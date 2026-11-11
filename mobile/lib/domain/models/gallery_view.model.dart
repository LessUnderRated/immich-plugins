import 'package:collection/collection.dart';

const mainGalleryViewScope = 'main';
const galleryViewType = 'GalleryViewV1';

enum GalleryViewSortField { createdAt, updatedAt, name, pixels, duration }

class GalleryViewSpec {
  final GalleryViewSortField sortField;
  final bool descending;
  final bool photos;
  final bool videos;
  final bool gifs;
  final Set<String> excludeAlbumIds;
  final Set<String> excludeAssetIds;

  const GalleryViewSpec({
    this.sortField = GalleryViewSortField.createdAt,
    this.descending = true,
    this.photos = true,
    this.videos = true,
    this.gifs = true,
    this.excludeAlbumIds = const {},
    this.excludeAssetIds = const {},
  });

  GalleryViewSpec withExcludedAssets(Set<String> assetIds) => GalleryViewSpec(
    sortField: sortField,
    descending: descending,
    photos: photos,
    videos: videos,
    gifs: gifs,
    excludeAlbumIds: excludeAlbumIds,
    excludeAssetIds: assetIds,
  );

  factory GalleryViewSpec.fromJson(Map<String, dynamic> json) {
    final sort = json['sort'] is Map ? json['sort'] as Map : const {};
    final include = json['include'] is Map ? json['include'] as Map : const {};
    final excluded = json['excludeAlbumIds'];
    return GalleryViewSpec(
      sortField:
          GalleryViewSortField.values.firstWhereOrNull((field) => field.name == sort['field']) ??
          GalleryViewSortField.createdAt,
      descending: sort['direction'] != 'asc',
      photos: include['photos'] != false,
      videos: include['videos'] != false,
      gifs: include['gifs'] != false,
      excludeAlbumIds: excluded is List ? excluded.map((id) => '$id').toSet() : const {},
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GalleryViewSpec &&
          other.sortField == sortField &&
          other.descending == descending &&
          other.photos == photos &&
          other.videos == videos &&
          other.gifs == gifs &&
          const SetEquality<String>().equals(other.excludeAlbumIds, excludeAlbumIds) &&
          const SetEquality<String>().equals(other.excludeAssetIds, excludeAssetIds);

  @override
  int get hashCode => Object.hash(
    sortField,
    descending,
    photos,
    videos,
    gifs,
    const SetEquality<String>().hash(excludeAlbumIds),
    const SetEquality<String>().hash(excludeAssetIds),
  );
}

class GalleryViewSelection {
  final String pluginName;
  final String methodName;
  final Map<String, dynamic> config;

  const GalleryViewSelection({required this.pluginName, required this.methodName, required this.config});

  String get key => '$pluginName#$methodName';

  factory GalleryViewSelection.fromJson(Map<String, dynamic> json) {
    final method = '${json['method']}';
    final separator = method.indexOf('#');
    return GalleryViewSelection(
      pluginName: separator < 0 ? method : method.substring(0, separator),
      methodName: separator < 0 ? '' : method.substring(separator + 1),
      config: json['config'] is Map ? Map<String, dynamic>.from(json['config'] as Map) : {},
    );
  }

  Map<String, dynamic> toJson() => {'method': key, 'config': config};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GalleryViewSelection && other.key == key && const DeepCollectionEquality().equals(other.config, config);

  @override
  int get hashCode => Object.hash(key, const DeepCollectionEquality().hash(config));
}
