import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/files_api.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/infrastructure/utils/plugin_http_client.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:openapi/api.dart' show QueryParam;

/// Network host functions beyond `httpRequest`: `net.fetch`, `net.api`, `net.server`, `net.status`.
class NetHostApi implements DataHostModule {
  final PluginPaths _paths;
  final ApiService _api;
  final StoreService _store;
  final ConnectivityApi _connectivity;

  const NetHostApi(this._paths, this._api, this._store, this._connectivity);

  @override
  Map<String, DataHostFunction> get functions => {
    'net.fetch': (plugin, args) => fetch(plugin, HostArgs(args).text(0, 'url'), HostArgs(args).map(1)),
    'net.api': (plugin, args) =>
        callApi(HostArgs(args).text(0, 'method'), HostArgs(args).text(1, 'path'), HostArgs(args).map(2)),
    'net.server': (plugin, args) async => server(),
    'net.status': (plugin, args) => status(),
  };

  @override
  Map<String, String> get docs => const {
    'net.fetch':
        '[url, { method, headers, body | bodyBase64 | bodyFile, multipart: { fields, files: [{ field, path, '
        'fileName?, contentType? }] }, responseType: "text" | "json" | "base64" | "file", responsePath?, '
        'timeoutSeconds = 120, followRedirects = true, useAppClient = false }] -> '
        '{ ok, status, headers, body | path, size, durationMs }',
    'net.api': '[method, path, { query?, body?, headers? }] -> { ok, status, headers, body } (Immich server API with '
        'the app login; 503 without a server)',
    'net.server': '[] -> { endpoint, serverUrl, loggedIn, headers }',
    'net.status': '[] -> { connected, wifi, cellular, vpn, unmetered }',
  };

  /// A request with the plugin's own client, or with the app's client (`useAppClient`: the app's TLS settings and
  /// custom headers, through the `net.request` hook).
  Future<Map<String, dynamic>> fetch(String plugin, String url, Map<String, dynamic> options) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw DataHostException.badRequest('Invalid URL $url');
    }
    final method = (options.text('method') ?? 'GET').toUpperCase();
    final headers = options.stringMap('headers');
    final multipart = options.object('multipart');
    final bodyFile = options.text('bodyFile');

    final http.BaseRequest request;
    if (multipart.isNotEmpty) {
      final form = http.MultipartRequest(method, uri)..fields.addAll(multipart.stringMap('fields'));
      for (final entry in multipart['files'] is List ? multipart['files'] as List : const []) {
        final file = entry is Map ? Map<String, dynamic>.from(entry) : <String, dynamic>{};
        final path = await _paths.resolve(plugin, file.text('path') ?? '');
        form.files.add(
          await http.MultipartFile.fromPath(
            file.text('field') ?? 'file',
            path,
            filename: file.text('fileName'),
            contentType: switch (file.text('contentType')) {
              final String type => _mediaType(type),
              null => null,
            },
          ),
        );
      }
      request = form;
    } else if (bodyFile != null) {
      final file = File(await _paths.resolve(plugin, bodyFile));
      if (!file.existsSync()) {
        throw DataHostException.notFound('File not found: $bodyFile');
      }
      final streamed = http.StreamedRequest(method, uri)..contentLength = await file.length();
      unawaited(file.openRead().pipe(streamed.sink));
      request = streamed;
    } else {
      final buffered = http.Request(method, uri);
      final bytes = PluginHttpClient.decodeBody(options);
      if (bytes != null) {
        buffered.bodyBytes = bytes;
        if (options['body'] is Map || options['body'] is List) {
          headers.putIfAbsent('content-type', () => 'application/json');
        }
      }
      request = buffered;
    }
    request
      ..headers.addAll(headers)
      ..followRedirects = options.flag('followRedirects') ?? true
      ..maxRedirects = options.integer('maxRedirects') ?? 5;

    final useApp = options.flag('useAppClient') == true;
    final client = useApp ? NetworkRepository.client : http.Client();
    final started = DateTime.now();
    try {
      final response = await client
          .send(request)
          .timeout(Duration(seconds: options.integer('timeoutSeconds') ?? 120));
      final result = <String, dynamic>{
        'ok': response.statusCode >= 200 && response.statusCode < 300,
        'status': response.statusCode,
        'headers': response.headers,
      };
      switch (options.text('responseType') ?? 'text') {
        case 'file':
          final path = await _paths.resolve(plugin, options.text('responsePath') ?? 'downloads/response');
          final file = File(path);
          await file.parent.create(recursive: true);
          await response.stream.pipe(file.openWrite());
          result['path'] = path;
          result['size'] = await file.length();
        case 'base64':
          final bytes = await response.stream.toBytes();
          result['body'] = base64Encode(bytes);
          result['size'] = bytes.length;
        case 'json':
          final text = await response.stream.bytesToString();
          result['body'] = text.isEmpty ? null : jsonDecode(text);
          result['size'] = text.length;
        default:
          final bytes = await response.stream.toBytes();
          result['body'] = utf8.decode(bytes, allowMalformed: true);
          result['size'] = bytes.length;
      }
      result['durationMs'] = DateTime.now().difference(started).inMilliseconds;
      return result;
    } on TimeoutException {
      throw const DataHostException(408, 'The request timed out');
    } finally {
      if (!useApp) {
        client.close();
      }
    }
  }

  static http.MediaType _mediaType(String value) {
    try {
      return http.MediaType.parse(value);
    } on FormatException {
      throw DataHostException.badRequest('Invalid content type $value');
    }
  }

  /// Calls the Immich server API (relative [path] such as `/assets/statistics`) with the app's login.
  Future<Map<String, dynamic>> callApi(String method, String path, Map<String, dynamic> options) async {
    if ((_store.tryGet(StoreKey.serverEndpoint) ?? '').isEmpty) {
      throw const DataHostException(503, 'The app is not connected to a server');
    }
    final query = options.object('query');
    final body = options['body'];
    final response = await _api.apiClient.invokeAPI(
      path.startsWith('/') ? path : '/$path',
      method.toUpperCase(),
      [
        for (final entry in query.entries)
          if (entry.value is List)
            for (final value in entry.value as List) QueryParam(entry.key, '$value')
          else
            QueryParam(entry.key, '${entry.value}'),
      ],
      body,
      options.stringMap('headers'),
      const {},
      body == null ? null : 'application/json',
    );
    final text = response.body;
    Object? decoded = text;
    if ((response.headers['content-type'] ?? '').contains('json') && text.isNotEmpty) {
      decoded = jsonDecode(text);
    }
    return {
      'ok': response.statusCode >= 200 && response.statusCode < 300,
      'status': response.statusCode,
      'headers': response.headers,
      'body': decoded,
    };
  }

  Map<String, dynamic> server() => {
    'endpoint': _store.tryGet(StoreKey.serverEndpoint),
    'serverUrl': _store.tryGet(StoreKey.serverUrl),
    'loggedIn': (_store.tryGet(StoreKey.accessToken) ?? '').isNotEmpty,
    'headers': ApiService.getRequestHeaders(),
  };

  Future<Map<String, dynamic>> status() async {
    final capabilities = await _connectivity.getCapabilities();
    return {
      'connected': capabilities.isNotEmpty,
      for (final capability in NetworkCapability.values) capability.name: capabilities.contains(capability),
    };
  }
}
