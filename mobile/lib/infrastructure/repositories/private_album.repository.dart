import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PrivateAlbumRepository {
  final _changes = StreamController<void>.broadcast();
  Set<String>? _cache;

  Stream<void> get changes => _changes.stream;

  Set<String> get cached => _cache ?? const {};

  Future<File> _file() async => File(p.join((await getApplicationDocumentsDirectory()).path, 'private_ids.json'));

  Future<Set<String>> ids() async {
    final cached = _cache;
    if (cached != null) {
      return cached;
    }
    final file = await _file();
    if (!file.existsSync()) {
      return _cache = const {};
    }
    try {
      return _cache = (jsonDecode(await file.readAsString()) as List).map((id) => '$id').toSet();
    } catch (_) {
      return _cache = const {};
    }
  }

  Future<void> _save(Set<String> ids) async {
    final file = await _file();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(ids.toList()), flush: true);
    await temp.rename(file.path);
    _cache = Set.unmodifiable(ids);
    _changes.add(null);
  }

  Future<int> add(Iterable<String> assetIds) async {
    final current = await ids();
    final next = {...current, ...assetIds};
    await _save(next);
    return next.length - current.length;
  }

  Future<int> remove(Iterable<String> assetIds) async {
    final current = await ids();
    final next = current.difference(assetIds.toSet());
    await _save(next);
    return current.length - next.length;
  }
}
