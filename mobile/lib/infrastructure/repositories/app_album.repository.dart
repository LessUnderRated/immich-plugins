import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class AppAlbum {
  final String id;
  final String name;
  final DateTime createdAt;
  final List<String> assetIds;

  const AppAlbum({required this.id, required this.name, required this.createdAt, required this.assetIds});

  factory AppAlbum.fromJson(Map<String, dynamic> json) => AppAlbum(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Album',
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int? ?? 0),
    assetIds: (json['assetIds'] as List? ?? const []).map((id) => '$id').toList(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'assetIds': assetIds,
  };

  AppAlbum copyWith({String? name, List<String>? assetIds}) =>
      AppAlbum(id: id, name: name ?? this.name, createdAt: createdAt, assetIds: assetIds ?? this.assetIds);
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

  Future<AppAlbum> create(String name, {List<String> assetIds = const []}) async {
    final albums = await list();
    final existing = albums.where((album) => album.name == name).firstOrNull;
    if (existing != null) {
      await addAssets(existing.id, assetIds);
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

  Future<int> addAssets(String albumId, List<String> assetIds) async {
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

  Future<int> removeAssets(String albumId, List<String> assetIds) async {
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

  Future<void> rename(String albumId, String name) async {
    final albums = [for (final album in await list()) album.id == albumId ? album.copyWith(name: name) : album];
    await _save(albums);
  }

  Future<void> delete(String albumId) async {
    await _save((await list()).where((album) => album.id != albumId).toList());
  }
}
