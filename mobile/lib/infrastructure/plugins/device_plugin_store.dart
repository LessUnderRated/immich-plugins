import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _bundledPlugins = ['immich-plugin-core'];
const _manifestFile = 'manifest.json';
const _wasmFile = 'plugin.wasm';
const _dexFile = 'plugin.dex';
final _validName = RegExp(r'^[A-Za-z0-9._-]+$');

class DevicePluginStore {
  final _log = Logger('DevicePluginStore');
  Directory? _root;

  Future<Directory> get root async {
    final existing = _root;
    if (existing != null) {
      return existing;
    }
    final directory = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'plugins'));
    await directory.create(recursive: true);
    return _root = directory;
  }

  Future<Directory?> dropFolder() async {
    final external = Platform.isAndroid ? await getExternalStorageDirectory() : null;
    if (external == null) {
      return null;
    }
    final directory = Directory(p.join(external.path, 'plugins'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> _file(String name) async => File(p.join((await root).path, name));

  Future<Map<String, dynamic>> readJson(String name) async {
    final file = await _file(name);
    if (!file.existsSync()) {
      return {};
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map);
    } catch (error) {
      _log.warning('Unable to read $name', error);
      return {};
    }
  }

  Future<void> writeJson(String name, Map<String, dynamic> value) async {
    final file = await _file(name);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(value), flush: true);
    await temp.rename(file.path);
  }

  Future<Set<String>> _disabled() async =>
      ((await readJson('state.json'))['disabled'] as List? ?? const []).whereType<String>().toSet();

  Future<void> setEnabled(String name, bool enabled) async {
    final state = await readJson('state.json');
    final disabled = (state['disabled'] as List? ?? const []).whereType<String>().toSet();
    enabled ? disabled.remove(name) : disabled.add(name);
    state['disabled'] = disabled.toList();
    await writeJson('state.json', state);
  }

  Future<List<DevicePlugin>> list() async {
    final directory = await root;
    final disabled = await _disabled();
    final plugins = <DevicePlugin>[];
    for (final entry in directory.listSync().whereType<Directory>()) {
      final manifest = File(p.join(entry.path, _manifestFile));
      final wasm = File(p.join(entry.path, _wasmFile));
      final dex = File(p.join(entry.path, _dexFile));
      final code = wasm.existsSync() ? wasm : dex;
      if (!manifest.existsSync() || !code.existsSync()) {
        continue;
      }
      try {
        final json = Map<String, dynamic>.from(jsonDecode(await manifest.readAsString()) as Map);
        final name = json['name'] as String;
        plugins.add(
          DevicePlugin.fromManifest(
            json,
            codePath: code.path,
            enabled: !disabled.contains(name),
            bundled: _bundledPlugins.contains(name),
          ),
        );
      } catch (error) {
        _log.warning('Skipping invalid plugin in ${entry.path}', error);
      }
    }
    plugins.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return plugins;
  }

  Future<void> installBundled() async {
    for (final name in _bundledPlugins) {
      try {
        final manifestText = await rootBundle.loadString('assets/plugins/$name/$_manifestFile');
        final manifest = Map<String, dynamic>.from(jsonDecode(manifestText) as Map);
        final installed = File(p.join((await root).path, name, _manifestFile));
        if (installed.existsSync()) {
          final current = jsonDecode(await installed.readAsString()) as Map;
          if (current['version'] == manifest['version']) {
            continue;
          }
        }
        final wasm = await rootBundle.load('assets/plugins/$name/$_wasmFile');
        await _write(name, manifestText, wasm.buffer.asUint8List(wasm.offsetInBytes, wasm.lengthInBytes), _wasmFile);
      } catch (error, stack) {
        _log.severe('Unable to install bundled plugin $name', error, stack);
      }
    }
  }

  Future<List<String>> installFromDropFolder() async {
    final folder = await dropFolder();
    if (folder == null) {
      return const [];
    }
    final installed = <String>[];
    for (final zip in folder.listSync().whereType<File>().where((file) => file.path.toLowerCase().endsWith('.zip'))) {
      try {
        installed.add(await installZip(await zip.readAsBytes()));
        await zip.rename('${zip.path}.installed');
      } catch (error) {
        _log.warning('Unable to install ${zip.path}', error);
      }
    }
    return installed;
  }

  Future<String> installZip(Uint8List bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final manifestEntry = archive.files
        .where((file) => file.isFile && p.basename(file.name) == _manifestFile)
        .fold<ArchiveFile?>(null, (best, file) => best == null || file.name.length < best.name.length ? file : best);
    if (manifestEntry == null) {
      throw const FormatException('The zip does not contain a manifest.json');
    }

    final manifestText = utf8.decode(manifestEntry.content);
    final manifest = Map<String, dynamic>.from(jsonDecode(manifestText) as Map);
    final name = manifest['name'];
    if (name is! String || !_validName.hasMatch(name)) {
      throw const FormatException('The manifest has an invalid plugin name');
    }

    final base = p.posix.dirname(manifestEntry.name);
    if (manifest['runtime'] == 'dex') {
      if (manifest['entry'] is! String) {
        throw const FormatException('A dex plugin manifest needs an "entry" class name');
      }
      final declaredDex = manifest['dexPath'] as String?;
      final dexName = declaredDex == null
          ? null
          : p.posix.normalize(p.posix.join(base == '.' ? '' : base, declaredDex));
      final dexEntry =
          archive.files.where((file) => file.isFile && file.name == dexName).firstOrNull ??
          archive.files.where((file) => file.isFile && file.name.toLowerCase().endsWith('.dex')).firstOrNull;
      if (dexEntry == null) {
        throw const FormatException('The zip does not contain a .dex file');
      }
      await _write(name, manifestText, dexEntry.content, _dexFile);
      return name;
    }

    final declared = manifest['wasmPath'] as String?;
    final wasmName = declared == null ? null : p.posix.normalize(p.posix.join(base == '.' ? '' : base, declared));
    final wasmEntry =
        archive.files.where((file) => file.isFile && file.name == wasmName).firstOrNull ??
        archive.files.where((file) => file.isFile && file.name.toLowerCase().endsWith('.wasm')).firstOrNull;
    if (wasmEntry == null) {
      throw const FormatException('The zip does not contain a .wasm file');
    }

    await _write(name, manifestText, wasmEntry.content, _wasmFile);
    return name;
  }

  Future<void> uninstall(String name) async {
    if (!_validName.hasMatch(name)) {
      return;
    }
    final directory = Directory(p.join((await root).path, name));
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _write(String name, String manifest, List<int> code, String codeFile) async {
    final directory = Directory(p.join((await root).path, name));
    final staging = Directory('${directory.path}.staging');
    if (staging.existsSync()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
    await File(p.join(staging.path, _manifestFile)).writeAsString(manifest, flush: true);
    await File(p.join(staging.path, codeFile)).writeAsBytes(code, flush: true);
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
    await staging.rename(directory.path);
  }

  Future<List<DeviceWorkflow>> workflows() async {
    final json = await readJson('workflows.json');
    return (json['workflows'] as List? ?? const [])
        .whereType<Map>()
        .map((workflow) => DeviceWorkflow.fromJson(Map<String, dynamic>.from(workflow)))
        .toList();
  }

  Future<void> saveWorkflows(List<DeviceWorkflow> workflows) =>
      writeJson('workflows.json', {'workflows': workflows.map((workflow) => workflow.toJson()).toList()});
}
