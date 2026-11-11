import 'package:immich_mobile/data/db/main/database.dart';
import 'package:photo_manager/photo_manager.dart';

class DuplicateGroup {
  final String keepId;
  final List<String> copyIds;
  final String name;

  const DuplicateGroup({required this.keepId, required this.copyIds, required this.name});
}

class DuplicateFinderRepository {
  final Drift _db;

  const DuplicateFinderRepository(this._db);

  Future<List<DuplicateGroup>> findCopies() async {
    final rows = await _db
        .customSelect(
          'SELECT id, name, created_at, width, height, duration_ms FROM local_asset_entity',
          readsFrom: {_db.localAssetEntity},
        )
        .get();

    final groups = <String, List<(String, String)>>{};
    for (final row in rows) {
      final key = [
        row.read<String>('name').toLowerCase(),
        row.data['created_at'],
        row.read<int?>('width'),
        row.read<int?>('height'),
        row.read<int?>('duration_ms'),
      ].join('|');
      groups.putIfAbsent(key, () => []).add((row.read<String>('id'), row.read<String>('name')));
    }

    int numeric(String id) => int.tryParse(id) ?? 0;
    return [
      for (final members in groups.values)
        if (members.length > 1)
          () {
            final sorted = [...members]..sort((a, b) => numeric(a.$1).compareTo(numeric(b.$1)));
            return DuplicateGroup(
              keepId: sorted.first.$1,
              copyIds: [for (final member in sorted.skip(1)) member.$1],
              name: sorted.first.$2,
            );
          }(),
    ];
  }

  Future<int> deleteCopies(List<DuplicateGroup> groups) async {
    final ids = [for (final group in groups) ...group.copyIds];
    if (ids.isEmpty) {
      return 0;
    }
    final deleted = await PhotoManager.editor.deleteWithIds(ids);
    return deleted.length;
  }
}
