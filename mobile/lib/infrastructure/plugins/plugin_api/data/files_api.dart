import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The private data folder of a plugin (the kernel knows where plugins live).
typedef PluginDirResolver = Future<Directory> Function(String plugin);

/// Resolves plugin paths: relative paths are inside the plugin's data folder, absolute paths are used as given
/// (plugins run with the app's permissions).
class PluginPaths {
  final PluginDirResolver dataDir;

  const PluginPaths(this.dataDir);

  Future<String> resolve(String plugin, String path) async {
    if (p.isAbsolute(path)) {
      return p.normalize(path);
    }
    final root = (await dataDir(plugin)).path;
    final resolved = p.normalize(p.join(root, path));
    if (!p.isWithin(root, resolved) && resolved != root) {
      throw DataHostException.badRequest('Relative paths must stay inside the plugin folder: $path');
    }
    return resolved;
  }
}

/// File system host functions beyond `readFile` / `writeFile`: `files.read`, `files.write`, `files.stat`,
/// `files.list`, `files.exists`, `files.mkdir`, `files.copy`, `files.move`, `files.delete`, `files.hash`,
/// `files.zip`, `files.unzip`, `files.paths`.
class FilesHostApi implements DataHostModule {
  final PluginPaths _paths;

  const FilesHostApi(this._paths);

  @override
  Map<String, DataHostFunction> get functions => {
    'files.read': (plugin, args) async =>
        read(await _path(plugin, args, 0), HostArgs(args).map(1)),
    'files.write': (plugin, args) async =>
        write(await _path(plugin, args, 0), HostArgs(args)[1], HostArgs(args).map(2)),
    'files.stat': (plugin, args) async => stat(await _path(plugin, args, 0)),
    'files.exists': (plugin, args) async => FileSystemEntity.typeSync(await _path(plugin, args, 0)) !=
        FileSystemEntityType.notFound,
    'files.list': (plugin, args) async => list(await _path(plugin, args, 0, fallback: '.'), HostArgs(args).map(1)),
    'files.mkdir': (plugin, args) async {
      await Directory(await _path(plugin, args, 0)).create(recursive: true);
      return null;
    },
    'files.copy': (plugin, args) async => copy(await _path(plugin, args, 0), await _path(plugin, args, 1)),
    'files.move': (plugin, args) async => move(await _path(plugin, args, 0), await _path(plugin, args, 1)),
    'files.delete': (plugin, args) async => delete(await _path(plugin, args, 0), HostArgs(args).map(1)),
    'files.hash': (plugin, args) async => hash(await _path(plugin, args, 0), HostArgs(args).map(1)),
    'files.zip': (plugin, args) async => zip(
      [for (final path in _list(args, 0)) await _paths.resolve(plugin, path)],
      await _path(plugin, args, 1),
    ),
    'files.unzip': (plugin, args) async => unzip(await _path(plugin, args, 0), await _path(plugin, args, 1)),
    'files.paths': (plugin, args) => paths(plugin),
  };

  @override
  Map<String, String> get docs => const {
    'files.read': '[path, { encoding: "utf8" | "base64", offset?, length? }] -> string',
    'files.write': '[path, data, { encoding: "utf8" | "base64", append? }] -> { path, size }',
    'files.stat': '[path] -> { path, type: "file" | "directory" | "link", size, modifiedAt } (404 when missing)',
    'files.exists': '[path] -> bool',
    'files.list': '[dir?, { recursive? }] -> [{ path, name, type, size, modifiedAt }]',
    'files.mkdir': '[path] -> null (creates parents)',
    'files.copy': '[from, to] -> { path }',
    'files.move': '[from, to] -> { path }',
    'files.delete': '[path, { recursive? }] -> { deleted }',
    'files.hash': '[path, { algorithm: "sha256" | "sha1" | "md5" }] -> hex string',
    'files.zip': '[[paths], zipPath] -> { path, size }',
    'files.unzip': '[zipPath, dir] -> { files: [paths] }',
    'files.paths': '[] -> { data, cache, temp, documents, support, external? }',
  };

  Future<String> _path(String plugin, List<dynamic> args, int index, {String? fallback}) {
    final value = HostArgs(args).optText(index) ?? fallback;
    if (value == null) {
      throw const DataHostException.badRequest('Missing argument path');
    }
    return _paths.resolve(plugin, value);
  }

  static List<String> _list(List<dynamic> args, int index) =>
      index < args.length && args[index] is List ? [for (final item in args[index] as List) '$item'] : const [];

  static Future<String> read(String path, Map<String, dynamic> options) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw DataHostException.notFound('File not found: $path');
    }
    final offset = options.integer('offset');
    final length = options.integer('length');
    final List<int> bytes;
    if (offset == null && length == null) {
      bytes = await file.readAsBytes();
    } else {
      final start = offset ?? 0;
      bytes = await file.openRead(start, length == null ? null : start + length).fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
    }
    return options['encoding'] == 'base64' ? base64Encode(bytes) : utf8.decode(bytes, allowMalformed: true);
  }

  static Future<Map<String, dynamic>> write(String path, Object? data, Map<String, dynamic> options) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final bytes = switch (data) {
      final String text when options['encoding'] == 'base64' => base64Decode(text),
      final String text => utf8.encode(text),
      null => const <int>[],
      _ => utf8.encode(jsonEncode(data)),
    };
    await file.writeAsBytes(bytes, mode: options.flag('append') == true ? FileMode.append : FileMode.write, flush: true);
    return {'path': path, 'size': await file.length()};
  }

  static Map<String, dynamic> _entry(FileSystemEntity entity, FileStat stat) => {
    'path': entity.path,
    'name': p.basename(entity.path),
    'type': switch (stat.type) {
      FileSystemEntityType.directory => 'directory',
      FileSystemEntityType.link => 'link',
      _ => 'file',
    },
    'size': stat.size,
    'modifiedAt': stat.modified.toUtc().toIso8601String(),
  };

  static Map<String, dynamic> stat(String path) {
    final stat = FileStat.statSync(path);
    if (stat.type == FileSystemEntityType.notFound) {
      throw DataHostException.notFound('Not found: $path');
    }
    return _entry(File(path), stat);
  }

  static Future<List<Map<String, dynamic>>> list(String path, Map<String, dynamic> options) async {
    final directory = Directory(path);
    if (!directory.existsSync()) {
      throw DataHostException.notFound('Folder not found: $path');
    }
    return [
      await for (final entity in directory.list(recursive: options.flag('recursive') == true, followLinks: false))
        _entry(entity, entity.statSync()),
    ];
  }

  static Future<Map<String, dynamic>> copy(String from, String to) async {
    final source = File(from);
    if (!source.existsSync()) {
      throw DataHostException.notFound('File not found: $from');
    }
    await File(to).parent.create(recursive: true);
    return {'path': (await source.copy(to)).path};
  }

  static Future<Map<String, dynamic>> move(String from, String to) async {
    final type = FileSystemEntity.typeSync(from);
    if (type == FileSystemEntityType.notFound) {
      throw DataHostException.notFound('Not found: $from');
    }
    await Directory(p.dirname(to)).create(recursive: true);
    try {
      final moved = type == FileSystemEntityType.directory
          ? await Directory(from).rename(to)
          : await File(from).rename(to);
      return {'path': moved.path};
    } on FileSystemException {
      // Across file systems: copy, then delete.
      if (type == FileSystemEntityType.directory) {
        rethrow;
      }
      await File(from).copy(to);
      await File(from).delete();
      return {'path': to};
    }
  }

  static Future<Map<String, dynamic>> delete(String path, Map<String, dynamic> options) async {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      return {'deleted': false};
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: options.flag('recursive') == true);
    } else {
      await File(path).delete();
    }
    return {'deleted': true};
  }

  static Future<String> hash(String path, Map<String, dynamic> options) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw DataHostException.notFound('File not found: $path');
    }
    final algorithm = switch (options['algorithm'] ?? 'sha256') {
      'sha256' => sha256,
      'sha1' => sha1,
      'md5' => md5,
      final other => throw DataHostException.badRequest('Unknown hash algorithm $other'),
    };
    return (await algorithm.bind(file.openRead()).first).toString();
  }

  static Future<Map<String, dynamic>> zip(List<String> paths, String target) async {
    if (paths.isEmpty) {
      throw const DataHostException.badRequest('Nothing to zip');
    }
    await File(target).parent.create(recursive: true);
    final encoder = ZipFileEncoder()..create(target);
    try {
      for (final path in paths) {
        if (FileSystemEntity.isDirectorySync(path)) {
          await encoder.addDirectory(Directory(path));
        } else {
          await encoder.addFile(File(path));
        }
      }
    } finally {
      await encoder.close();
    }
    return {'path': target, 'size': await File(target).length()};
  }

  static Future<Map<String, dynamic>> unzip(String zipPath, String directory) async {
    if (!File(zipPath).existsSync()) {
      throw DataHostException.notFound('File not found: $zipPath');
    }
    final archive = ZipDecoder().decodeStream(InputFileStream(zipPath));
    final root = p.normalize(directory);
    final written = <String>[];
    try {
      for (final entry in archive) {
        final target = p.normalize(p.join(root, entry.name));
        if (!p.isWithin(root, target)) {
          continue;
        }
        if (entry.isFile) {
          await File(target).parent.create(recursive: true);
          final output = OutputFileStream(target);
          entry.writeContent(output);
          await output.close();
          written.add(target);
        } else {
          await Directory(target).create(recursive: true);
        }
      }
    } finally {
      await archive.clear();
    }
    return {'files': written};
  }

  Future<Map<String, dynamic>> paths(String plugin) async {
    final external = Platform.isAndroid ? await getExternalStorageDirectory() : null;
    return {
      'data': (await _paths.dataDir(plugin)).path,
      'cache': (await getApplicationCacheDirectory()).path,
      'temp': (await getTemporaryDirectory()).path,
      'documents': (await getApplicationDocumentsDirectory()).path,
      'support': (await getApplicationSupportDirectory()).path,
      'external': ?external?.path,
    };
  }
}
