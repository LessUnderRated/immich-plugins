import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class AppAlbum {
  final String id;
  final String name;
  final DateTime createdAt;
  final List<String> assetIds;

  /// Asset shown as the album cover; the first asset when null.
  final String? coverAssetId;
  final String description;

  const AppAlbum({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.assetIds,
    this.coverAssetId,
    this.description = '',
  });

  factory AppAlbum.fromJson(Map<String, dynamic> json) => AppAlbum(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Album',
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int? ?? 0),
    assetIds: (json['assetIds'] as List? ?? const []).map((id) => '$id').toList(),
    coverAssetId: json['coverAssetId'] as String?,
    description: json['description'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'assetIds': assetIds,
    if (coverAssetId != null) 'coverAssetId': coverAssetId,
    if (description.isNotEmpty) 'description': description,
  };

  /// The JSON plugins see (`kind: "app"`), same shape as remote and device albums.
  Map<String, dynamic> toPluginJson() => {
    'id': id,
    'kind': 'app',
    'name': name,
    'description': description,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'coverAssetId': coverAssetId ?? assetIds.firstOrNull,
    'assetCount': assetIds.length,
    'assetIds': assetIds,
  };

  /// The cover asset: [coverAssetId] when it is still in the album, otherwise the first asset.
  String? get effectiveCoverAssetId =>
      coverAssetId != null && assetIds.contains(coverAssetId) ? coverAssetId : assetIds.firstOrNull;

  AppAlbum copyWith({String? name, List<String>? assetIds, String? coverAssetId, String? description}) => AppAlbum(
    id: id,
    name: name ?? this.name,
    createdAt: createdAt,
    assetIds: assetIds ?? this.assetIds,
    coverAssetId: coverAssetId ?? this.coverAssetId,
    description: description ?? this.description,
  );
}

class AppAlbumRepository {
  final _changes = StreamController<void>.broadcast();
  List<AppAlbum>? _cache;

  Stream<void> get changes => _changes.stream;

  Future<File> _file() async {
    final directory = await getApplicationDocumentsDirectory();
    return File(p.join(directory.path, 'albums.json'));
  }

  Future<List<AppAlbum>> list() async {
    final cached = _cache;
    if (cached != null) {
      return cached;
    }
    final file = await _file();
    if (!file.existsSync()) {
      return _cache = [];
    }
    try {
      final albums = (jsonDecode(await file.readAsString()) as List)
          .whereType<Map>()
          .map((album) => AppAlbum.fromJson(Map<String, dynamic>.from(album)))
          .toList();
      return _cache = albums;
    } catch (_) {
      return _cache = [];
    }
  }

  Future<AppAlbum?> get(String id) async => (await list()).where((album) => album.id == id).firstOrNull;

  Future<void> _save(List<AppAlbum> albums) async {
    final file = await _file();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(albums.map((album) => album.toJson()).toList()), flush: true);
    await temp.rename(file.path);
    _cache = albums;
    _changes.add(null);
  }

  Future<AppAlbum> create(String name, {List<String> assetIds = const []}) => PluginHooks.run<AppAlbum>(
    DataHooks.albumCreate,
    () => {'kind': 'app', 'name': name, 'assetIds': assetIds},
    () => _create(name, assetIds: assetIds),
    withArgs: (args) => _create(PluginArgs.string(args['name']) ?? name, assetIds: PluginArgs.strings(args['assetIds'])),
    encode: (album) => album.toPluginJson(),
    event: DataEvents.albumCreated,
    eventData: (args, album) => album.toPluginJson(),
  );

  Future<AppAlbum> _create(String name, {List<String> assetIds = const []}) async {
    final albums = await list();
    final existing = albums.where((album) => album.name == name).firstOrNull;
    if (existing != null) {
      await _addAssets(existing.id, assetIds);
      return (await get(existing.id))!;
    }
    final album = AppAlbum(
      id: const Uuid().v4(),
      name: name,
      createdAt: DateTime.now(),
      assetIds: assetIds.toSet().toList(),
    );
    await _save([...albums, album]);
    return album;
  }

  Future<int> addAssets(String albumId, List<String> assetIds) => PluginHooks.run<int>(
    DataHooks.albumAddAssets,
    () => {'kind': 'app', 'id': albumId, 'assetIds': assetIds},
    () => _addAssets(albumId, assetIds),
    withArgs: (args) => _addAssets(PluginArgs.string(args['id']) ?? albumId, PluginArgs.strings(args['assetIds'])),
    encode: (added) => added,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.albumAssetsAdded,
    eventData: (args, added) => {...args, 'added': added},
  );

  Future<int> _addAssets(String albumId, List<String> assetIds) async {
    final albums = [...await list()];
    final index = albums.indexWhere((album) => album.id == albumId);
    if (index == -1) {
      throw StateError('Album not found');
    }
    final current = albums[index].assetIds;
    final added = assetIds.where((id) => !current.contains(id)).toSet().toList();
    if (added.isEmpty) {
      return 0;
    }
    albums[index] = albums[index].copyWith(assetIds: [...current, ...added]);
    await _save(albums);
    return added.length;
  }

  Future<int> removeAssets(String albumId, List<String> assetIds) => PluginHooks.run<int>(
    DataHooks.albumRemoveAssets,
    () => {'kind': 'app', 'id': albumId, 'assetIds': assetIds},
    () => _removeAssets(albumId, assetIds),
    withArgs: (args) =>
        _removeAssets(PluginArgs.string(args['id']) ?? albumId, PluginArgs.strings(args['assetIds'])),
    encode: (removed) => removed,
    decode: (json) => PluginArgs.integer(json) ?? 0,
    event: DataEvents.albumAssetsRemoved,
    eventData: (args, removed) => {...args, 'removed': removed},
  );

  Future<int> _removeAssets(String albumId, List<String> assetIds) async {
    final albums = [...await list()];
    final index = albums.indexWhere((album) => album.id == albumId);
    if (index == -1) {
      return 0;
    }
    final remove = assetIds.toSet();
    final current = albums[index].assetIds;
    final kept = current.where((id) => !remove.contains(id)).toList();
    albums[index] = albums[index].copyWith(assetIds: kept);
    await _save(albums);
    return current.length - kept.length;
  }

  Future<void> rename(String albumId, String name) => PluginHooks.run<void>(
    DataHooks.albumRename,
    () => {'kind': 'app', 'id': albumId, 'name': name},
    () => _update(albumId, name: name),
    withArgs: (args) => _update(PluginArgs.string(args['id']) ?? albumId, name: PluginArgs.string(args['name'])),
    event: DataEvents.albumRenamed,
  );

  /// Changes the cover and/or description; runs as `album.update`.
  Future<void> update(String albumId, {String? coverAssetId, String? description}) => PluginHooks.run<void>(
    DataHooks.albumUpdate,
    () => {
      'kind': 'app',
      'id': albumId,
      'coverAssetId': ?coverAssetId,
      'description': ?description,
    },
    () => _update(albumId, coverAssetId: coverAssetId, description: description),
    withArgs: (args) => _update(
      PluginArgs.string(args['id']) ?? albumId,
      name: PluginArgs.string(args['name']),
      coverAssetId: PluginArgs.string(args['coverAssetId']),
      description: PluginArgs.string(args['description']),
    ),
    event: DataEvents.albumUpdated,
  );

  Future<void> _update(String albumId, {String? name, String? coverAssetId, String? description}) async {
    final albums = [
      for (final album in await list())
        album.id == albumId
            ? album.copyWith(name: name, coverAssetId: coverAssetId, description: description)
            : album,
    ];
    await _save(albums);
  }

  Future<void> delete(String albumId) => PluginHooks.run<void>(
    DataHooks.albumDelete,
    () => {'kind': 'app', 'id': albumId},
    () => _delete(albumId),
    withArgs: (args) => _delete(PluginArgs.string(args['id']) ?? albumId),
    event: DataEvents.albumDeleted,
  );

  Future<void> _delete(String albumId) async {
    await _save((await list()).where((album) => album.id != albumId).toList());
  }

  /// Removes [assetIds] from every album, e.g. after the assets were deleted from the device.
  Future<int> forgetAssets(Iterable<String> assetIds) async {
    final remove = assetIds.toSet();
    var removed = 0;
    final albums = <AppAlbum>[];
    for (final album in await list()) {
      final kept = album.assetIds.where((id) => !remove.contains(id)).toList();
      removed += album.assetIds.length - kept.length;
      albums.add(kept.length == album.assetIds.length ? album : album.copyWith(assetIds: kept));
    }
    if (removed > 0) {
      await _save(albums);
    }
    return removed;
  }
}
