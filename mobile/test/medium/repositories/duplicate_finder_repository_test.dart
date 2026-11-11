import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/duplicate_finder.repository.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;

  setUp(() => ctx = MediumRepositoryContext());
  tearDown(() async => ctx.dispose());

  test('keeps the oldest id and marks later copies', () async {
    final taken = DateTime.utc(2026, 11, 2, 12, 14);
    await ctx.newLocalAsset(id: '100', name: 'IMG_1.jpg', createdAt: taken, width: 4000, height: 3000);
    await ctx.newLocalAsset(id: '250', name: 'IMG_1.jpg', createdAt: taken, width: 4000, height: 3000);
    await ctx.newLocalAsset(id: '300', name: 'img_1.JPG', createdAt: taken, width: 4000, height: 3000);
    await ctx.newLocalAsset(id: '120', name: 'IMG_2.jpg', createdAt: taken, width: 4000, height: 3000);
    await ctx.newLocalAsset(id: '130', name: 'IMG_1.jpg', createdAt: taken, width: 1000, height: 750);

    final groups = await DuplicateFinderRepository(ctx.db).findCopies();

    expect(groups, hasLength(1));
    expect(groups.single.keepId, '100');
    expect(groups.single.copyIds, ['250', '300']);
  });

  test('finds nothing when every photo is unique', () async {
    await ctx.newLocalAsset(id: '1', name: 'a.jpg');
    await ctx.newLocalAsset(id: '2', name: 'b.jpg');

    expect(await DuplicateFinderRepository(ctx.db).findCopies(), isEmpty);
  });
}
