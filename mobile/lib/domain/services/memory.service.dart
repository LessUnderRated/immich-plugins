import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/infrastructure/repositories/memory.repository.dart';

/// Accesses Memories; a specialized collection of assets with some novel display mechanism
class MemoryService {
  final MemoryRepository _repository;

  const MemoryService(this._repository);

  /// Today's memories; plugins can filter, sort or extend them through `memory.query` (`scope: "lane"`).
  Future<List<Memory>> getMemoryLane(String ownerId) async => PluginHooks.filterList<Memory>(
    DataHooks.memoryQuery,
    () => {'scope': 'lane', 'ownerId': ownerId},
    await _repository.getAll(ownerId),
    PluginJson.memories,
  );

  /// Every memory; plugins can change the list through `memory.query` (`scope: "all"`).
  Future<List<Memory>> getAll(String ownerId, {bool onlyFavorites = false}) async => PluginHooks.filterList<Memory>(
    DataHooks.memoryQuery,
    () => {'scope': 'all', 'ownerId': ownerId, 'onlyFavorites': onlyFavorites},
    await _repository.getAll(ownerId, onlyToday: false, onlyFavorites: onlyFavorites),
    PluginJson.memories,
  );

  Future<Memory?> get(String memoryId) {
    return _repository.get(memoryId);
  }

  Future<int> getCount() {
    return _repository.getCount();
  }
}
