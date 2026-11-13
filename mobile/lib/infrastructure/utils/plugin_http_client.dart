import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';

/// The app's HTTP client with the `net.request` hook: every server API call, upload, sync stream and map style
/// request goes through it.
///
/// Hook arguments: `{ method, url, headers, body?, bodyBase64?, bodyType: "none" | "text" | "bytes" | "stream",
/// contentLength? }`. Request bodies are included for buffered requests only; streamed bodies (uploads, multipart)
/// are passed through untouched unless a plugin replaces them with `body` / `bodyBase64`.
///
/// * `before` may change `method`, `url`, `headers` or the body, cancel the request, or set `captureResponse: true`
///   to receive the response body in the `after` phase.
/// * `instead` may answer with `{ status, headers?, body? | bodyBase64?, reasonPhrase? }` without contacting the
///   server.
/// * `after` receives `{ status, headers, reasonPhrase, contentLength, body?/bodyBase64? }` and may return a
///   replacement response of the same shape.
///
/// When no plugin uses the hook the inner client is called directly.
class PluginHttpClient extends http.BaseClient {
  final http.Client _inner;

  PluginHttpClient(this._inner);

  /// Responses whose bodies were buffered for `after` handlers (`captureResponse`).
  static final _captured = Expando<Uint8List>('net.response.body');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final hooked = PluginHooks.has(DataHooks.netRequest);
    final listens = PluginHooks.listens(DataEvents.netCompleted);
    if (!hooked && !listens) {
      return _inner.send(request);
    }
    return hooked ? _hooked(request) : _timed(request, () => _inner.send(request));
  }

  Future<http.StreamedResponse> _hooked(http.BaseRequest request) async {
    final body = request is http.Request ? request.bodyBytes : null;
    var capture = false;
    final response = await PluginHooks.run<http.StreamedResponse>(
      DataHooks.netRequest,
      () => {
        'method': request.method,
        'url': request.url.toString(),
        'headers': request.headers,
        'contentLength': request.contentLength,
        ...encodeBody(body, request is http.Request ? request.headers['content-type'] : null),
        if (request is! http.Request) 'bodyType': 'stream',
      },
      () => _timed(request, () => _inner.send(request)),
      withArgs: (args) async {
        capture = args['captureResponse'] == true;
        final changed = _rebuild(request, body, args);
        final response = await _timed(changed, () => _inner.send(changed));
        return capture ? _buffer(response) : response;
      },
      encode: _encodeResponse,
      decode: (json) => decodeResponse(json, request),
    );
    return response;
  }

  Future<http.StreamedResponse> _timed(http.BaseRequest request, Future<http.StreamedResponse> Function() send) async {
    final started = DateTime.now();
    final response = await send();
    PluginHooks.emit(
      DataEvents.netCompleted,
      () => {
        'method': request.method,
        'url': request.url.toString(),
        'status': response.statusCode,
        'durationMs': DateTime.now().difference(started).inMilliseconds,
      },
    );
    return response;
  }

  /// Rebuilds the request from plugin-changed hook arguments. A streamed body that the plugin did not replace is
  /// forwarded unchanged.
  static http.BaseRequest _rebuild(http.BaseRequest original, Uint8List? body, PluginHookArgs args) {
    final method = PluginArgs.string(args['method']) ?? original.method;
    final url = Uri.tryParse(PluginArgs.string(args['url']) ?? '') ?? original.url;
    final headers = args['headers'] is Map
        ? {for (final entry in (args['headers'] as Map).entries) '${entry.key}': '${entry.value}'}
        : original.headers;
    final replacement = decodeBody(args);

    if (replacement != null || original is http.Request) {
      final request = http.Request(method, url)
        ..headers.addAll(headers)
        ..followRedirects = original.followRedirects
        ..maxRedirects = original.maxRedirects
        ..persistentConnection = original.persistentConnection;
      final bytes = replacement ?? body;
      if (bytes != null) {
        request.bodyBytes = bytes;
      }
      return request;
    }

    final request = http.StreamedRequest(method, url)
      ..headers.addAll(headers)
      ..contentLength = original.contentLength
      ..followRedirects = original.followRedirects
      ..maxRedirects = original.maxRedirects
      ..persistentConnection = original.persistentConnection;
    unawaited(
      original.finalize().pipe(request.sink).catchError((Object error, StackTrace stack) {
        request.sink.addError(error, stack);
        return request.sink.close();
      }),
    );
    return request;
  }

  static Future<http.StreamedResponse> _buffer(http.StreamedResponse response) async {
    final bytes = await response.stream.toBytes();
    final buffered = http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
    _captured[buffered] = bytes;
    return buffered;
  }

  static Object? _encodeResponse(http.StreamedResponse response) => {
    'status': response.statusCode,
    'headers': response.headers,
    'reasonPhrase': response.reasonPhrase,
    'contentLength': response.contentLength,
    ...encodeBody(_captured[response], response.headers['content-type']),
  };

  /// `{ body }` for UTF-8 text, `{ bodyBase64 }` for binary data, nothing for no body.
  static Map<String, dynamic> encodeBody(Uint8List? bytes, String? contentType) {
    if (bytes == null) {
      return const {'bodyType': 'none'};
    }
    final text = _isText(contentType) ? _tryUtf8(bytes) : null;
    return text != null
        ? {'bodyType': 'text', 'body': text}
        : {'bodyType': 'bytes', 'bodyBase64': base64Encode(bytes)};
  }

  static Uint8List? decodeBody(Map<dynamic, dynamic> json) {
    final base64 = json['bodyBase64'];
    if (base64 is String) {
      return base64Decode(base64);
    }
    final body = json['body'];
    if (body is String) {
      return Uint8List.fromList(utf8.encode(body));
    }
    if (body is Map || body is List) {
      return Uint8List.fromList(utf8.encode(jsonEncode(body)));
    }
    return null;
  }

  /// A response built from a plugin's `{ status, headers?, body? | bodyBase64?, reasonPhrase? }`.
  static http.StreamedResponse decodeResponse(Object? json, http.BaseRequest request) {
    if (json is! Map) {
      throw const FormatException('A net.request result must be an object with a status');
    }
    final bytes = decodeBody(json) ?? Uint8List(0);
    final headers = json['headers'] is Map
        ? {for (final entry in (json['headers'] as Map).entries) '${entry.key}'.toLowerCase(): '${entry.value}'}
        : <String, String>{};
    final response = http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      PluginArgs.integer(json['status']) ?? 200,
      contentLength: bytes.length,
      request: request,
      headers: headers,
      reasonPhrase: PluginArgs.string(json['reasonPhrase']),
    );
    _captured[response] = bytes;
    return response;
  }

  static bool _isText(String? contentType) {
    if (contentType == null) {
      return true;
    }
    final type = contentType.toLowerCase();
    return type.startsWith('text/') ||
        type.contains('json') ||
        type.contains('xml') ||
        type.contains('x-www-form-urlencoded') ||
        type.contains('javascript');
  }

  static String? _tryUtf8(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  @override
  void close() => _inner.close();
}
