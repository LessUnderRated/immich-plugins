import 'package:collection/collection.dart';

const mainGalleryViewScope = 'main';

enum GallerySort {
  newest,
  oldest,
  recentlyModified,
  leastRecentlyModified,
  nameAscending,
  nameDescending,
  largest,
  smallest,
}

class GalleryViewOptions {
  final GallerySort sort;
  final bool showPhotos;
  final bool showVideos;
  final bool showGifs;
  final Set<String> hiddenAlbumIds;

  const GalleryViewOptions({
    this.sort = GallerySort.newest,
    this.showPhotos = true,
    this.showVideos = true,
    this.showGifs = true,
    this.hiddenAlbumIds = const {},
  });

  bool get isDefault => this == const GalleryViewOptions();

  GalleryViewOptions copyWith({
    GallerySort? sort,
    bool? showPhotos,
    bool? showVideos,
    bool? showGifs,
    Set<String>? hiddenAlbumIds,
  }) => GalleryViewOptions(
    sort: sort ?? this.sort,
    showPhotos: showPhotos ?? this.showPhotos,
    showVideos: showVideos ?? this.showVideos,
    showGifs: showGifs ?? this.showGifs,
    hiddenAlbumIds: hiddenAlbumIds ?? this.hiddenAlbumIds,
  );

  Map<String, Object?> toJson() => {
    'sort': sort.name,
    'showPhotos': showPhotos,
    'showVideos': showVideos,
    'showGifs': showGifs,
    'hiddenAlbumIds': hiddenAlbumIds.toList(),
  };

  factory GalleryViewOptions.fromJson(Map<String, Object?> json) => GalleryViewOptions(
    sort: GallerySort.values.firstWhereOrNull((sort) => sort.name == json['sort']) ?? GallerySort.newest,
    showPhotos: json['showPhotos'] as bool? ?? true,
    showVideos: json['showVideos'] as bool? ?? true,
    showGifs: json['showGifs'] as bool? ?? true,
    hiddenAlbumIds: (json['hiddenAlbumIds'] as List? ?? const []).whereType<String>().toSet(),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GalleryViewOptions &&
          other.sort == sort &&
          other.showPhotos == showPhotos &&
          other.showVideos == showVideos &&
          other.showGifs == showGifs &&
          const SetEquality<String>().equals(other.hiddenAlbumIds, hiddenAlbumIds);

  @override
  int get hashCode =>
      Object.hash(sort, showPhotos, showVideos, showGifs, const SetEquality<String>().hash(hiddenAlbumIds));
}
