import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/gallery_view.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late TimelineRepository sut;

  setUpAll(() async {
    await initializeDateFormatting();
  });

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = TimelineRepository(ctx.db);

    await ctx.newLocalAsset(
      id: 'photo-big',
      name: 'b.jpg',
      type: AssetType.image,
      width: 4000,
      height: 3000,
      createdAt: DateTime.utc(2024, 1, 3),
    );
    await ctx.newLocalAsset(
      id: 'photo-small',
      name: 'a.jpg',
      type: AssetType.image,
      width: 100,
      height: 100,
      createdAt: DateTime.utc(2024, 1, 1),
    );
    await ctx.newLocalAsset(
      id: 'gif',
      name: 'c.GIF',
      type: AssetType.image,
      width: 500,
      height: 500,
      createdAt: DateTime.utc(2024, 1, 2),
    );
    await ctx.newLocalAsset(
      id: 'video',
      name: 'd.mp4',
      type: AssetType.video,
      width: 1920,
      height: 1080,
      durationMs: 9000,
      createdAt: DateTime.utc(2024, 1, 4),
    );

    await ctx.newLocalAlbum(id: 'screenshots', name: 'Screenshots');
    await ctx.newLocalAlbumAsset(albumId: 'screenshots', assetId: 'photo-small');
    await ctx.newLocalAlbumAsset(albumId: 'screenshots', assetId: 'gif');
  });

  tearDown(() async {
    await ctx.dispose();
  });

  Future<List<String>> ids(TimelineQuery query) async =>
      (await query.assetSource(0, 50)).map((asset) => (asset as LocalAsset).id).toList();

  Future<int> count(TimelineQuery query) async =>
      (await query.bucketSource().first).fold<int>(0, (sum, bucket) => sum + bucket.assetCount);

  test('defaults keep newest first and show everything', () async {
    final query = sut.deviceLibrary(GroupAssetsBy.none, view: const GalleryViewSpec());
    expect(await ids(query), ['video', 'photo-big', 'gif', 'photo-small']);
    expect(await count(query), 4);
  });

  test('sorts by name and by pixels', () async {
    expect(
      await ids(
        sut.deviceLibrary(
          GroupAssetsBy.none,
          view: const GalleryViewSpec(sortField: GalleryViewSortField.name, descending: false),
        ),
      ),
      ['photo-small', 'photo-big', 'gif', 'video'],
    );
    expect(
      await ids(
        sut.deviceLibrary(GroupAssetsBy.none, view: const GalleryViewSpec(sortField: GalleryViewSortField.pixels)),
      ),
      ['photo-big', 'video', 'gif', 'photo-small'],
    );
  });

  test('filters photos, videos and gifs', () async {
    final onlyVideos = sut.deviceLibrary(GroupAssetsBy.none, view: const GalleryViewSpec(photos: false, gifs: false));
    expect(await ids(onlyVideos), ['video']);
    expect(await count(onlyVideos), 1);

    final noGifs = sut.deviceLibrary(GroupAssetsBy.none, view: const GalleryViewSpec(gifs: false));
    expect(await ids(noGifs), ['video', 'photo-big', 'photo-small']);
  });

  test('hides excluded albums from the main gallery only', () async {
    const view = GalleryViewSpec(excludeAlbumIds: {'screenshots'});
    expect(await ids(sut.deviceLibrary(GroupAssetsBy.none, view: view)), ['video', 'photo-big']);
    expect(await ids(sut.localAlbum('screenshots', GroupAssetsBy.none, view: view)), ['gif', 'photo-small']);
  });

  test('parses a plugin view spec', () {
    final spec = GalleryViewSpec.fromJson({
      'sort': {'field': 'duration', 'direction': 'asc'},
      'include': {'photos': false},
      'excludeAlbumIds': ['a', 'b'],
    });
    expect(spec.sortField, GalleryViewSortField.duration);
    expect(spec.descending, isFalse);
    expect(spec.photos, isFalse);
    expect(spec.videos, isTrue);
    expect(spec.excludeAlbumIds, {'a', 'b'});
  });
}
