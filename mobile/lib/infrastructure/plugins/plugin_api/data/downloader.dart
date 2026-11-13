import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/files_api.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// One download of `files.download`.
class PluginDownload {
  final String id;
  final String plugin;
  final String url;
  final String path;
  int received = 0;
  int? total;
  String state = 'running';
  final DateTime startedAt = DateTime.now();
  StreamSubscription<List<int>>? _subscription;
  Completer<void>? _done;
  bool _cancelled = false;
  bool _discard = false;

  PluginDownload({required this.id, required this.plugin, required this.url, required this.path});

  Future<void> _stop({required bool discard}) async {
    _cancelled = true;
    _discard = discard;
    await _subscription?.cancel();
    _subscription = null;
    final done = _done;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'plugin': plugin,
    'url': url,
    'path': path,
    'received': received,
    'total': total,
    'progress': total == null || total == 0 ? null : received / total!,
    'state': state,
    'startedAt': startedAt.toUtc().toIso8601String(),
  };
}

/// Downloads files for plugins (models, weights, assets) with progress events, resume, checksum and cancel:
/// `files.download`, `files.cancelDownload`, `files.downloads`.
///
/// Data goes to `<path>.part` first; a later download of the same path resumes it with an HTTP range request when
/// the server supports ranges. With `sha256` the finished file is verified and deleted on mismatch (status 422).
/// Events: `download.started`, `download.progress` (`{ id, received, total, progress }`, at most every 250 ms),
/// `download.completed`, `download.failed`, `download.cancelled`.
class PluginDownloader implements DataHostModule {
  final PluginPaths _paths;
  final http.Client Function() _client;
  final Map<String, PluginDownload> _active = {};

  /// [client] makes the HTTP client of one download (a plain client by default; pass the app's client to send
  /// downloads through `net.request`).
  PluginDownloader(this._paths, {http.Client Function()? client}) : _client = client ?? http.Client.new;

  @override
  Map<String, DataHostFunction> get functions => {
    'files.download': (plugin, args) => download(plugin, HostArgs(args).text(0, 'url'), HostArgs(args).map(1)),
    'files.cancelDownload': (plugin, args) async =>
        cancel(HostArgs(args).text(0, 'id'), discard: HostArgs(args).map(1).flag('discard') ?? false),
    'files.downloads': (plugin, args) async => [
      for (final download in _active.values)
        if (HostArgs(args).map(0).flag('all') == true || download.plugin == plugin) download.toJson(),
    ],
  };

  @override
  Map<String, String> get docs => const {
    'files.download':
        '[url, { path?, sha256?, headers?, resume = true, background = false, timeoutSeconds?, id? }] -> '
        '{ id, path, size, sha256, resumed } (background: { id, path } at once, the rest through events)',
    'files.cancelDownload': '[id, { discard? }] -> bool (discard deletes the partial file)',
    'files.downloads': '[{ all? }] -> [{ id, plugin, url, path, received, total, progress, state }]',
  };

  Future<Map<String, dynamic>> download(String plugin, String url, Map<String, dynamic> options) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw DataHostException.badRequest('Invalid URL $url');
    }
    final path = await _paths.resolve(plugin, options.text('path') ?? p.join('downloads', _fileName(uri)));
    final id = options.text('id') ?? const Uuid().v4();
    if (_active.containsKey(id)) {
      throw DataHostException(409, 'Download $id is already running');
    }

    Future<Map<String, dynamic>> run() => PluginHooks.run<Map<String, dynamic>>(
      DataHooks.fileDownload,
      () => {'id': id, 'plugin': plugin, 'url': url, 'path': path, 'headers': options.stringMap('headers')},
      () => _download(id, plugin, uri, path, options),
      withArgs: (args) => _download(
        id,
        plugin,
        Uri.tryParse(PluginArgs.string(args['url']) ?? '') ?? uri,
        PluginArgs.string(args['path']) ?? path,
        {...options, 'headers': args['headers'] ?? options['headers']},
      ),
      encode: (result) => result,
      decode: (json) => json is Map ? Map<String, dynamic>.from(json) : const {},
    );

    if (options.flag('background') == true) {
      unawaited(run().catchError((Object _) => const <String, dynamic>{}));
      return {'id': id, 'path': path};
    }
    return run();
  }

  static String _fileName(Uri uri) {
    final last = uri.pathSegments.where((segment) => segment.isNotEmpty).lastOrNull;
    return last == null || last.isEmpty ? 'download_${DateTime.now().millisecondsSinceEpoch}' : last;
  }

  Future<Map<String, dynamic>> _download(
    String id,
    String plugin,
    Uri uri,
    String path,
    Map<String, dynamic> options,
  ) async {
    final download = PluginDownload(id: id, plugin: plugin, url: uri.toString(), path: path);
    _active[id] = download;
    final partial = File('$path.part');
    await partial.parent.create(recursive: true);
    final resume = options.flag('resume') ?? true;
    final client = _client();
    final timeout = Duration(seconds: options.integer('timeoutSeconds') ?? 60);
    var resumed = false;

    try {
      var offset = resume && partial.existsSync() ? await partial.length() : 0;
      final request = http.Request('GET', uri)..headers.addAll(options.stringMap('headers'));
      if (offset > 0) {
        request.headers['range'] = 'bytes=$offset-';
      }
      final response = await client.send(request).timeout(timeout);
      if (response.statusCode == 416 && offset > 0) {
        // The partial file is already complete.
        await response.stream.drain<void>();
      } else {
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw DataHostException(response.statusCode, 'Download failed with HTTP ${response.statusCode}');
        }
        resumed = response.statusCode == 206 && offset > 0;
        if (!resumed) {
          offset = 0;
        }
        final length = response.contentLength;
        download
          ..received = offset
          ..total = length == null ? null : length + offset;
        PluginHooks.emit(DataEvents.downloadStarted, () => {...download.toJson(), 'resumed': resumed});

        final sink = partial.openWrite(mode: resumed ? FileMode.append : FileMode.write);
        final done = download._done = Completer<void>();
        var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
        download._subscription = response.stream
            .timeout(timeout)
            .listen(
              (chunk) {
                sink.add(chunk);
                download.received += chunk.length;
                final now = DateTime.now();
                if (now.difference(lastEmit) >= const Duration(milliseconds: 250)) {
                  lastEmit = now;
                  PluginHooks.emit(DataEvents.downloadProgress, download.toJson);
                }
              },
              onError: (Object error, StackTrace stack) {
                if (!done.isCompleted) {
                  done.completeError(error, stack);
                }
              },
              onDone: () {
                if (!done.isCompleted) {
                  done.complete();
                }
              },
              cancelOnError: true,
            );
        try {
          await done.future;
        } finally {
          await sink.flush();
          await sink.close();
        }
      }

      if (download._cancelled) {
        throw const _Cancelled();
      }

      final digest = (await sha256.bind(partial.openRead()).first).toString();
      final expected = options.text('sha256')?.toLowerCase();
      if (expected != null && expected != digest) {
        await partial.delete();
        throw DataHostException(422, 'Checksum mismatch: expected $expected, got $digest');
      }
      final target = File(path);
      if (target.existsSync()) {
        await target.delete();
      }
      await partial.rename(path);
      final result = {
        'id': id,
        'path': path,
        'size': await target.length(),
        'sha256': digest,
        'resumed': resumed,
      };
      download.state = 'completed';
      PluginHooks.emit(DataEvents.downloadCompleted, () => {...download.toJson(), ...result});
      return result;
    } on _Cancelled {
      download.state = 'cancelled';
      if (download._discard && partial.existsSync()) {
        await partial.delete();
      }
      PluginHooks.emit(DataEvents.downloadCancelled, download.toJson);
      throw DataHostException(499, 'Download $id was cancelled');
    } catch (error) {
      download.state = 'failed';
      PluginHooks.emit(DataEvents.downloadFailed, () => {...download.toJson(), 'error': error.toString()});
      rethrow;
    } finally {
      _active.remove(id);
      client.close();
    }
  }

  /// Stops a running download; the partial file stays for a later resume unless [discard].
  Future<bool> cancel(String id, {bool discard = false}) async {
    final download = _active[id];
    if (download == null) {
      return false;
    }
    await download._stop(discard: discard);
    return true;
  }

  /// Cancels every download of [plugin] (e.g. when it is disabled or uninstalled).
  Future<void> cancelAll(String plugin) async {
    for (final download in _active.values.where((download) => download.plugin == plugin).toList()) {
      await cancel(download.id);
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
