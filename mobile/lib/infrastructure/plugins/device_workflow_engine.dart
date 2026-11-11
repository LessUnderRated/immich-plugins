import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';
import 'package:immich_mobile/domain/services/offline_user.service.dart';
import 'package:immich_mobile/infrastructure/plugins/device_plugin_store.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_host_extras.dart';
import 'package:immich_mobile/infrastructure/plugins/wasm_plugin_runtime.dart';
import 'package:immich_mobile/infrastructure/repositories/app_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/device_edit.repository.dart';
import 'package:logging/logging.dart';
import 'package:photo_manager/photo_manager.dart' hide AssetType;

const _engineStateFile = 'engine.json';
const _batchSize = 200;

class HostFunctionException implements Exception {
  final int status;
  final String message;

  const HostFunctionException(this.status, this.message);

  @override
  String toString() => message;
}

class DeviceWorkflowRun {
  final DateTime at;
  final String workflow;
  final String asset;
  final String result;

  const DeviceWorkflowRun({required this.at, required this.workflow, required this.asset, required this.result});
}

class DeviceWorkflowEngine {
  final Drift _db;
  final DevicePluginStore _store;
  final WasmPluginRuntime _runtime;
  final DeviceEditRepository _edits;
  final AppAlbumRepository _albums;
  final _log = Logger('DeviceWorkflowEngine');

  final Map<String, DevicePlugin> _loaded = {};
  final List<DeviceWorkflowRun> recentRuns = [];
  final _changes = StreamController<void>.broadcast();
  bool _processing = false;
  bool _pending = false;
  Future<void>? _ready;

  DeviceWorkflowEngine(this._db, this._store, this._runtime, this._edits, this._albums) {
    _runtime.hostHandler = _handleHostCall;
  }

  Stream<void> get changes => _changes.stream;

  Future<void> ensureReady() => _ready ??= _initialize();

  Future<void> _initialize() async {
    await _store.installBundled();
    await _store.installFromDropFolder();
    await reload();
  }

  Future<List<DevicePlugin>> plugins() => _store.list();

  Future<List<(DevicePlugin, DevicePluginMethod)>> galleryViewMethods() async {
    await ensureReady();
    return [
      for (final plugin in await _store.list())
        if (plugin.enabled && _loaded.containsKey(plugin.name))
          for (final method in plugin.methods)
            if (method.isGalleryView) (plugin, method),
    ];
  }

  late final PluginHostExtras _extras = PluginHostExtras(() => _store.root);

  Future<List<(DevicePlugin, DevicePluginMethod)>> assetActionMethods() async {
    await ensureReady();
    return [
      for (final plugin in await _store.list())
        if (plugin.enabled && _loaded.containsKey(plugin.name))
          for (final method in plugin.methods)
            if (method.isAssetAction) (plugin, method),
    ];
  }

  Future<Map<String, dynamic>?> runAssetAction(
    String plugin,
    String method,
    List<LocalAsset> assets,
    Map<String, dynamic> config,
  ) async {
    final response = await callPluginMethod(plugin, method, {
      'type': 'AssetActionV1',
      'config': config,
      'workflow': {'id': 'asset-action', 'authToken': '', 'stepId': method},
      'data': {
        'assets': [for (final asset in assets) await _assetV1(asset)],
      },
    });
    _changes.add(null);
    return response;
  }

  Future<List<Map<String, dynamic>>> _listAssets(Map<String, dynamic> options) async {
    final offset = (options['offset'] as num?)?.toInt() ?? 0;
    final limit = ((options['limit'] as num?)?.toInt() ?? 100).clamp(1, 1000);
    final albumId = options['albumId'] as String?;
    final appAlbum = albumId == null ? null : await _albums.get(albumId);

    final query = _db.localAssetEntity.select()
      ..orderBy([(row) => OrderingTerm.desc(row.createdAt), (row) => OrderingTerm.asc(row.id)])
      ..limit(limit, offset: offset);
    if (appAlbum != null) {
      query.where((row) => row.id.isIn(appAlbum.assetIds));
    } else if (albumId != null) {
      query.where(
        (row) => row.id.isInQuery(
          _db.selectOnly(_db.localAlbumAssetEntity)
            ..addColumns([_db.localAlbumAssetEntity.assetId])
            ..where(_db.localAlbumAssetEntity.albumId.equals(albumId)),
        ),
      );
    }

    return [for (final row in await query.get()) await _assetV1(row.toDto())];
  }

  Future<Map<String, dynamic>> _readImage(String assetId, Map<String, dynamic> options) async {
    final bytes = options['original'] == true ? await _edits.readOriginal(assetId) : await _edits.readCurrent(assetId);
    if (bytes == null) {
      throw const HostFunctionException(404, 'Image file not found');
    }
    return {
      'assetId': assetId,
      ...await PluginHostExtras.encodePixels(bytes, maxSize: (options['maxSize'] as num?)?.toInt()),
    };
  }

  Future<Map<String, dynamic>> _writeImage(String assetId, Map<String, dynamic> image) async {
    final asset = await _localAsset(assetId);
    final bytes = await PluginHostExtras.decodePixels(image, png: _edits.replacesAsPng(asset));
    final result = await _edits.replaceImage(asset, bytes);
    if (result.createdId != null) {
      await _markCreated(result.createdId!);
    }
    return {'assetId': assetId, 'outcome': result.outcome.name, 'createdId': result.createdId};
  }

  Future<List<(DevicePlugin, DevicePluginMethod)>> censorStyleMethods() async {
    await ensureReady();
    return [
      for (final plugin in await _store.list())
        if (plugin.enabled && _loaded.containsKey(plugin.name))
          for (final method in plugin.methods)
            if (method.isCensorStyle) (plugin, method),
    ];
  }

  Future<Map<String, dynamic>?> callPluginMethod(String plugin, String method, Map<String, dynamic> input) async {
    await ensureReady();
    if (!_loaded.containsKey(plugin)) {
      throw StateError('Plugin $plugin is not installed or is disabled');
    }
    return _runtime.call(plugin, method, input);
  }

  Future<void> reload() async {
    final plugins = await _store.list();
    for (final name in _loaded.keys.toList()) {
      final current = plugins.where((plugin) => plugin.name == name).firstOrNull;
      if (current == null || !current.enabled || current.version != _loaded[name]!.version) {
        await _runtime.unload(name);
        _loaded.remove(name);
      }
    }
    for (final plugin in plugins.where((plugin) => plugin.enabled && !_loaded.containsKey(plugin.name))) {
      try {
        await _runtime.load(plugin);
        _loaded[plugin.name] = plugin;
      } catch (error, stack) {
        _log.severe('Unable to load plugin ${plugin.name}', error, stack);
      }
    }
    _changes.add(null);
  }

  Future<String> installZip(Uint8List bytes) async {
    final name = await _store.installZip(bytes);
    await reload();
    return name;
  }

  Future<List<String>> installFromDropFolder() async {
    final installed = await _store.installFromDropFolder();
    await reload();
    return installed;
  }

  Future<void> setPluginEnabled(String name, bool enabled) async {
    await _store.setEnabled(name, enabled);
    await reload();
  }

  Future<void> uninstall(String name) async {
    await _store.uninstall(name);
    await reload();
  }

  Future<List<DeviceWorkflow>> workflows() => _store.workflows();

  Future<void> saveWorkflow(DeviceWorkflow workflow) async {
    final workflows = await _store.workflows();
    final index = workflows.indexWhere((existing) => existing.id == workflow.id);
    index == -1 ? workflows.add(workflow) : workflows[index] = workflow;
    await _store.saveWorkflows(workflows);
    _changes.add(null);
  }

  Future<void> deleteWorkflow(String id) async {
    final workflows = await _store.workflows();
    await _store.saveWorkflows(workflows.where((workflow) => workflow.id != id).toList());
    _changes.add(null);
  }

  StreamSubscription<void>? _watch;
  Timer? _debounce;

  void startWatching() {
    _watch ??= _db.tableUpdates(TableUpdateQuery.onTable(_db.localAssetEntity)).listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 2), () => unawaited(processNewAssets()));
    });
    unawaited(processNewAssets());
  }

  Future<void> processNewAssets() async {
    if (_processing) {
      _pending = true;
      return;
    }
    _processing = true;
    try {
      await ensureReady();
      do {
        _pending = false;
        await _processBatches();
      } while (_pending);
    } catch (error, stack) {
      _log.severe('Workflow processing failed', error, stack);
    } finally {
      _processing = false;
    }
  }

  Future<void> _processBatches() async {
    final state = await _store.readJson(_engineStateFile);
    final watermark = state['watermark'] as int?;
    if (watermark == null) {
      state['watermark'] = await _maxNumericId();
      await _store.writeJson(_engineStateFile, state);
      return;
    }

    final workflows = (await _store.workflows())
        .where((workflow) => workflow.enabled && workflow.trigger == deviceAssetCreateTrigger)
        .toList();

    var current = watermark;
    while (true) {
      final assets = await _assetsAfter(current);
      if (assets.isEmpty) {
        break;
      }
      for (final asset in assets) {
        current = int.parse(asset.id);
        final created = await _consumeCreated(asset.id);
        if (!created) {
          for (final workflow in workflows) {
            await _run(workflow, asset);
          }
        }
        final latest = await _store.readJson(_engineStateFile);
        latest['watermark'] = current;
        await _store.writeJson(_engineStateFile, latest);
      }
    }
  }

  Future<int> _maxNumericId() async {
    final row = await _db.customSelect('SELECT MAX(CAST(id AS INTEGER)) AS max_id FROM local_asset_entity').getSingle();
    return row.read<int?>('max_id') ?? 0;
  }

  Future<List<LocalAsset>> _assetsAfter(int watermark) {
    final query = _db.localAssetEntity.select()
      ..where((row) => CustomExpression<bool>('CAST(id AS INTEGER) > $watermark'))
      ..orderBy([(row) => OrderingTerm.asc(CustomExpression<int>('CAST(id AS INTEGER)'))])
      ..limit(_batchSize);
    return query.map((row) => row.toDto()).get();
  }

  Future<bool> _consumeCreated(String id) async {
    final state = await _store.readJson(_engineStateFile);
    final created = (state['created'] as List? ?? const []).whereType<String>().toList();
    if (!created.remove(id)) {
      return false;
    }
    state['created'] = created;
    await _store.writeJson(_engineStateFile, state);
    return true;
  }

  Future<void> _markCreated(String id) async {
    final state = await _store.readJson(_engineStateFile);
    final created = (state['created'] as List? ?? const []).whereType<String>().toList()..add(id);
    state['created'] = created.length > 500 ? created.sublist(created.length - 500) : created;
    await _store.writeJson(_engineStateFile, state);
  }

  Future<String> runOnAsset(DeviceWorkflow workflow, LocalAsset asset) async {
    await ensureReady();
    return _run(workflow, asset);
  }

  Future<String> _run(DeviceWorkflow workflow, LocalAsset asset) async {
    var result = 'completed';
    try {
      final data = <String, dynamic>{'asset': await _assetV1(asset)};
      var steps = workflow.steps;
      for (final step in workflow.steps.where((step) => step.enabled)) {
        final plugin = _loaded[step.pluginName];
        final method = plugin?.method(step.methodName);
        if (plugin == null || method == null) {
          result = 'stopped: ${step.pluginName}#${step.methodName} is not available';
          break;
        }

        final response = await _runtime.call(plugin.name, method.name, {
          'trigger': workflow.trigger,
          'type': deviceAssetType,
          'config': step.config,
          'workflow': {'id': workflow.id, 'authToken': workflow.id, 'stepId': step.id},
          'data': data,
        });

        final changes = response?['changes'];
        if (changes is Map && changes['asset'] is Map) {
          final assetChanges = Map<String, dynamic>.from(changes['asset'] as Map);
          await _applyChanges(asset, assetChanges);
          (data['asset'] as Map<String, dynamic>).addAll(assetChanges);
        }

        final config = response?['config'];
        if (config is Map) {
          steps = [
            for (final existing in steps)
              existing.id == step.id ? existing.copyWith(config: Map<String, dynamic>.from(config)) : existing,
          ];
          await saveWorkflow(workflow.copyWith(steps: steps));
        }

        final flow = response?['workflow'];
        if (flow is Map && flow['continue'] == false) {
          result = 'halted at ${method.title}';
          break;
        }
      }
    } catch (error, stack) {
      _log.warning('Workflow ${workflow.name} failed for ${asset.name}', error, stack);
      result = 'failed: $error';
    } finally {}

    recentRuns.insert(
      0,
      DeviceWorkflowRun(at: DateTime.now(), workflow: workflow.name, asset: asset.name, result: result),
    );
    if (recentRuns.length > 50) {
      recentRuns.removeLast();
    }
    _changes.add(null);
    return result;
  }

  Future<Map<String, dynamic>> _assetV1(LocalAsset asset) async {
    final entity = await AssetEntity.fromId(asset.id);
    final relativePath = entity?.relativePath;
    final tags = await _tagsFor(asset.id);
    return {
      'id': asset.id,
      'ownerId': offlineUserId,
      'type': switch (asset.type) {
        AssetType.image => 'IMAGE',
        AssetType.video => 'VIDEO',
        AssetType.audio => 'AUDIO',
        AssetType.other => 'OTHER',
      },
      'originalFileName': asset.name,
      'originalPath': relativePath == null
          ? asset.name
          : '/${relativePath.replaceAll(RegExp(r'/+$'), '')}/${asset.name}',
      'isFavorite': asset.isFavorite,
      'visibility': 'timeline',
      'livePhotoVideoId': asset.playbackStyle == AssetPlaybackStyle.livePhoto ? asset.id : null,
      'checksum': asset.checksum,
      'fileCreatedAt': asset.createdAt.toUtc().toIso8601String(),
      'fileModifiedAt': asset.updatedAt.toUtc().toIso8601String(),
      'localDateTime': asset.createdAt.toLocal().toIso8601String(),
      'duration': asset.durationMs == null ? null : Duration(milliseconds: asset.durationMs!).toString(),
      'isOffline': false,
      'deletedAt': null,
      'tags': [
        for (final tag in tags) {'id': tag, 'value': tag, 'name': tag.split('/').last},
      ],
      'ocr': null,
      'exifInfo': {
        'exifImageWidth': asset.width,
        'exifImageHeight': asset.height,
        'orientation': asset.orientation.toString(),
        'latitude': asset.latitude,
        'longitude': asset.longitude,
        'dateTimeOriginal': asset.createdAt.toUtc().toIso8601String(),
        'modifyDate': asset.updatedAt.toUtc().toIso8601String(),
        'timeZone': null,
        'make': null,
        'model': null,
        'lensModel': null,
        'fNumber': null,
        'focalLength': null,
        'iso': null,
        'exposureTime': null,
        'fileSizeInByte': null,
        'city': null,
        'state': null,
        'country': null,
        'description': null,
        'rating': null,
        'fps': null,
        'livePhotoCID': null,
        'projectionType': null,
        'profileDescription': null,
        'colorspace': null,
        'bitsPerSample': null,
        'tags': tags,
      },
    };
  }

  Future<void> _applyChanges(LocalAsset asset, Map<String, dynamic> changes) async {
    final favorite = changes['isFavorite'];
    if (favorite is bool && favorite != asset.isFavorite) {
      final entity = await AssetEntity.fromId(asset.id);
      if (entity != null) {
        Platform.isAndroid
            ? await PhotoManager.editor.android.favoriteAsset(entity: entity, favorite: favorite)
            : await PhotoManager.editor.darwin.favoriteAsset(entity: entity, favorite: favorite);
      }
    }
    if (changes['visibility'] != null && changes['visibility'] != 'timeline') {
      _log.info('Visibility "${changes['visibility']}" is not available on the device; ignoring for ${asset.name}');
    }
  }

  Future<String> _handleHostCall(String plugin, String name, String input) async {
    try {
      final payload = jsonDecode(input) as Map;
      final args = (payload['args'] as List?) ?? const [];
      final response = await _dispatch(plugin, name, args);
      return jsonEncode({'success': true, 'response': response});
    } on HostFunctionException catch (error) {
      return jsonEncode({'success': false, 'status': error.status, 'message': error.message});
    } catch (error, stack) {
      _log.warning('Host function $name failed for $plugin', error, stack);
      return jsonEncode({'success': false, 'status': 500, 'message': error.toString()});
    }
  }

  Future<Object?> _dispatch(String plugin, String name, List<dynamic> args) {
    Map<String, dynamic> arg(int index) =>
        index < args.length && args[index] is Map ? Map<String, dynamic>.from(args[index] as Map) : {};
    String text(int index) => index < args.length ? '${args[index]}' : '';

    return switch (name) {
      'searchAlbums' => _searchAlbums(),
      'createAlbum' => _createAlbum(arg(0)),
      'addAssetsToAlbum' => _addToAlbum(text(0), _strings(arg(1)['ids'])),
      'addAssetsToAlbums' => _addToAlbums(_strings(arg(0)['albumIds']), _strings(arg(0)['assetIds'])),
      'httpRequest' => _httpRequest(text(0), arg(1)),
      'bulkTagAssets' => _bulkTag(_strings(arg(0)['tagIds']), _strings(arg(0)['assetIds'])),
      'getAssetEdits' => _getAssetEdits(text(0)),
      'editAsset' => _editAsset(text(0), arg(1)),
      'removeAssetEdits' => _removeAssetEdits(text(0)),
      'listAssets' => _listAssets(arg(0)),
      'getAsset' => _localAsset(text(0)).then(_assetV1),
      'readImage' => _readImage(text(0), arg(1)),
      'writeImage' => _writeImage(text(0), arg(1)),
      'readFile' => _extras.readFile(plugin, text(0)),
      'writeFile' => _extras.writeFile(plugin, text(0), arg(1)),
      'listFiles' => _extras.listFiles(plugin, text(0)),
      'deleteFile' => _extras.deleteFile(plugin, text(0)).then((_) => null),
      'getStorage' => _extras.getStorage(plugin, text(0)),
      'setStorage' => _extras.setStorage(plugin, text(0), args.length > 1 ? args[1] : null).then((_) => null),
      _ => throw HostFunctionException(501, 'Host function $name is not available on the device'),
    };
  }

  static List<String> _strings(Object? value) => value is List ? value.map((item) => '$item').toList() : const [];

  Future<List<Map<String, dynamic>>> _searchAlbums() async => [
    for (final album in await _albums.list())
      {'id': album.id, 'albumName': album.name, 'assetCount': album.assetIds.length, 'shared': false},
  ];

  Future<Map<String, dynamic>> _createAlbum(Map<String, dynamic> dto) async {
    final name = (dto['albumName'] as String? ?? '').trim();
    if (name.isEmpty) {
      throw const HostFunctionException(400, 'Album name is invalid');
    }
    final album = await _albums.create(name, assetIds: _strings(dto['assetIds']));
    return {'id': album.id, 'albumName': album.name, 'assetCount': album.assetIds.length, 'shared': false};
  }

  Future<List<Map<String, dynamic>>> _addToAlbums(List<String> albumIds, List<String> assetIds) async {
    final results = <Map<String, dynamic>>[];
    for (final albumId in albumIds) {
      results.addAll(await _addToAlbum(albumId, assetIds));
    }
    return results;
  }

  Future<List<Map<String, dynamic>>> _addToAlbum(String albumId, List<String> assetIds) async {
    final album = await _albums.get(albumId);
    if (album == null) {
      throw HostFunctionException(404, 'Album $albumId not found');
    }
    final existing = album.assetIds.toSet();
    await _albums.addAssets(albumId, assetIds);
    return [
      for (final assetId in assetIds)
        existing.contains(assetId)
            ? {'id': assetId, 'success': false, 'error': 'duplicate'}
            : {'id': assetId, 'success': true},
    ];
  }

  Future<Map<String, dynamic>> _httpRequest(String url, Map<String, dynamic> options) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const HostFunctionException(400, 'Invalid URL');
    }

    final request = http.Request((options['method'] as String? ?? 'GET').toUpperCase(), uri);
    final headers = options['headers'];
    if (headers is Map) {
      request.headers.addAll(headers.map((key, value) => MapEntry('$key', '$value')));
    }
    final body = options['body'];
    final bodyBase64 = options['bodyBase64'];
    if (bodyBase64 is String) {
      request.bodyBytes = base64Decode(bodyBase64);
    } else if (body is String) {
      request.body = body;
    }
    final timeout = options['timeoutSeconds'];
    final response = await http.Response.fromStream(
      await request.send().timeout(Duration(seconds: timeout is num ? timeout.toInt() : 120)),
    );
    final binary = options['responseType'] == 'base64';
    return {
      'ok': response.statusCode >= 200 && response.statusCode < 300,
      'status': response.statusCode,
      'headers': response.headers,
      'body': binary ? base64Encode(response.bodyBytes) : response.body,
    };
  }

  Future<List<String>> _tagsFor(String assetId) async {
    final state = await _store.readJson(_engineStateFile);
    final tags = state['tags'];
    return tags is Map ? _strings(tags[assetId]) : const [];
  }

  Future<List<String>> knownTags() async {
    final state = await _store.readJson(_engineStateFile);
    final tags = state['tags'];
    if (tags is! Map) {
      return const [];
    }
    return tags.values.expand(_strings).toSet().toList()..sort();
  }

  Future<Map<String, dynamic>> _bulkTag(List<String> tagIds, List<String> assetIds) async {
    final state = await _store.readJson(_engineStateFile);
    final tags = state['tags'] is Map ? Map<String, dynamic>.from(state['tags'] as Map) : <String, dynamic>{};
    var count = 0;
    for (final assetId in assetIds) {
      final current = _strings(tags[assetId]).toSet();
      final before = current.length;
      current.addAll(tagIds);
      count += current.length - before;
      tags[assetId] = current.toList();
    }
    state['tags'] = tags;
    await _store.writeJson(_engineStateFile, state);
    return {'count': count};
  }

  Future<LocalAsset> _localAsset(String assetId) async {
    final row = await (_db.localAssetEntity.select()..where((row) => row.id.equals(assetId))).getSingleOrNull();
    if (row == null) {
      throw const HostFunctionException(404, 'Asset not found');
    }
    return row.toDto();
  }

  Future<Map<String, dynamic>> _getAssetEdits(String assetId) async => {
    'assetId': assetId,
    'edits': await _edits.getEditsJson(assetId),
  };

  Future<Map<String, dynamic>> _editAsset(String assetId, Map<String, dynamic> dto) async {
    final rawEdits = dto['edits'] is List ? dto['edits'] as List : const [];
    final edits = rawEdits.whereType<Map>().map(assetEditFromJson).nonNulls.toList();
    if (edits.isEmpty) {
      throw const HostFunctionException(400, 'No valid edits');
    }

    final result = await _edits.applyEdits(await _localAsset(assetId), edits);
    if (result.createdId != null) {
      await _markCreated(result.createdId!);
    }
    return _getAssetEdits(assetId);
  }

  Future<void> _removeAssetEdits(String assetId) async {
    await _edits.removeEdits(await _localAsset(assetId));
  }
}
