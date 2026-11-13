import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/models/folder/recursive_folder.model.dart';
import 'package:immich_mobile/models/folder/root_folder.model.dart';
import 'package:immich_mobile/repositories/folder_api.repository.dart';
import 'package:logging/logging.dart';

final folderServiceProvider = Provider((ref) => FolderService(ref.watch(folderApiRepositoryProvider)));

class FolderService {
  final FolderApiRepository _folderApiRepository;
  final Logger _log = Logger("FolderService");

  FolderService(this._folderApiRepository);

  /// Plugins can hide, reorder or add folder paths through `folder.query` (`scope: "paths"`).
  Future<RootFolder> getFolderStructure(SortOrder order) async {
    final paths = await PluginHooks.filterList<String>(
      DataHooks.folderQuery,
      () => {'scope': 'paths', 'order': order.name},
      await _folderApiRepository.getAllUniquePaths(),
      () => PluginListCodec<String>(
        id: (path) => path,
        toJson: (path) => {'id': path, 'path': path},
        fromJson: (json) => PluginArgs.string(json['path'] ?? json['id']),
      ),
    );

    // Create folder structure
    final Map<String, List<RecursiveFolder>> folderMap = {};

    for (String fullPath in paths) {
      if (fullPath == '/') {
        continue;
      }

      // Ensure the path starts with a slash
      if (!fullPath.startsWith('/')) {
        fullPath = '/$fullPath';
      }

      final List<String> segments = fullPath.split('/')..removeWhere((s) => s.isEmpty);

      String currentPath = '';

      for (int i = 0; i < segments.length; i++) {
        final String parentPath = currentPath.isEmpty ? '_root_' : currentPath;
        currentPath = i == 0 ? '/${segments[i]}' : '$currentPath/${segments[i]}';

        if (!folderMap.containsKey(parentPath)) {
          folderMap[parentPath] = [];
        }

        if (!folderMap[parentPath]!.any((f) => f.name == segments[i])) {
          folderMap[parentPath]!.add(
            RecursiveFolder(path: parentPath == '_root_' ? '' : parentPath, name: segments[i], subfolders: []),
          );
          // Sort folders based on order parameter
          folderMap[parentPath]!.sort(
            (a, b) => order == SortOrder.desc ? b.name.compareTo(a.name) : a.name.compareTo(b.name),
          );
        }
      }
    }

    void attachSubfolders(RecursiveFolder folder) {
      final String fullPath = folder.path.isEmpty ? '/${folder.name}' : '${folder.path}/${folder.name}';

      if (folderMap.containsKey(fullPath)) {
        folder.subfolders.addAll(folderMap[fullPath]!);
        // Sort subfolders based on order parameter
        folder.subfolders.sort((a, b) => order == SortOrder.desc ? b.name.compareTo(a.name) : a.name.compareTo(b.name));
        for (var subfolder in folder.subfolders) {
          attachSubfolders(subfolder);
        }
      }
    }

    final List<RecursiveFolder> rootSubfolders = folderMap['_root_'] ?? [];
    // Sort root subfolders based on order parameter
    rootSubfolders.sort((a, b) => order == SortOrder.desc ? b.name.compareTo(a.name) : a.name.compareTo(b.name));

    for (var folder in rootSubfolders) {
      attachSubfolders(folder);
    }

    return RootFolder(subfolders: rootSubfolders, path: '/');
  }

  /// Plugins can filter or sort the assets of a folder through `folder.query` (`scope: "assets"`).
  Future<List<RemoteAssetExif>> getFolderAssets(RootFolder folder, SortOrder order) async =>
      PluginHooks.filterList<RemoteAssetExif>(
        DataHooks.folderQuery,
        () => {
          'scope': 'assets',
          'path': folder is RecursiveFolder ? (folder.path.isEmpty ? folder.name : '${folder.path}/${folder.name}') : '/',
          'order': order.name,
        },
        await _getFolderAssets(folder, order),
        () => PluginJson.list<RemoteAssetExif>((asset) => asset.id, PluginJson.asset),
      );

  Future<List<RemoteAssetExif>> _getFolderAssets(RootFolder folder, SortOrder order) async {
    try {
      if (folder is RecursiveFolder) {
        String fullPath = folder.path.isEmpty ? folder.name : '${folder.path}/${folder.name}';
        fullPath = fullPath[0] == '/' ? fullPath.substring(1) : fullPath;
        final result = await _folderApiRepository.getAssetsForPath(fullPath);

        if (order == SortOrder.desc) {
          result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        } else {
          result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        }

        return result;
      }
      final result = await _folderApiRepository.getAssetsForPath('/');
      return result;
    } catch (e, stack) {
      _log.severe("Failed to fetch assets for folder ${folder is RecursiveFolder ? folder.name : "root"}", e, stack);
      return [];
    }
  }
}
