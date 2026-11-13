import 'dart:async';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_bridge.dart';

/// Emits the viewer area's events. Nothing is built unless a plugin listens.
abstract final class ViewerEvents {
  static bool listens(String event) => PluginHooks.listens(event);

  static void emit(String event, Map<String, dynamic> Function() data) => PluginHooks.emit(event, data);

  /// Emits [event] with `asset` (AssetV1, or null) merged with [data].
  static void emitAsset(String event, BaseAsset? asset, [Map<String, dynamic> Function()? data]) {
    if (!PluginHooks.listens(event)) {
      return;
    }
    unawaited(_emitAsset(event, asset, data));
  }

  /// Emits [event] with a list of AssetV1 under `assets` merged with [data].
  static void emitAssets(String event, List<BaseAsset> assets, [Map<String, dynamic> Function()? data]) {
    if (!PluginHooks.listens(event)) {
      return;
    }
    unawaited(() async {
      final json = [for (final asset in assets) await ViewerPlugins.assetJson(asset)];
      PluginHooks.emit(event, () => {'assets': json, ...?data?.call()});
    }());
  }

  static Future<void> _emitAsset(String event, BaseAsset? asset, Map<String, dynamic> Function()? data) async {
    final json = asset == null ? null : await ViewerPlugins.assetJson(asset);
    PluginHooks.emit(event, () => {'asset': json, ...?data?.call()});
  }
}

/// MemoryV1 JSON for memory events.
Map<String, dynamic> memoryJson(Memory memory) => {
  'id': memory.id,
  'type': memory.type.name,
  'year': memory.data.year,
  'personName': memory.data.personName,
  'isSaved': memory.isSaved,
  'memoryAt': memory.memoryAt.toUtc().toIso8601String(),
  'assetIds': [for (final asset in memory.assets) asset.id],
};

/// Rate-limits one event stream: the first call goes out at once, later calls within [interval] are coalesced and
/// the latest data goes out when the interval ends (trailing edge), so the last value is never lost.
class EventThrottle {
  final String event;
  final Duration interval;

  DateTime? _lastSent;
  Timer? _timer;
  Map<String, dynamic> Function()? _pending;

  EventThrottle(this.event, this.interval);

  void call(Map<String, dynamic> Function() data) {
    if (!PluginHooks.listens(event)) {
      return;
    }
    final now = DateTime.now();
    final last = _lastSent;
    if (last == null || now.difference(last) >= interval) {
      _send(data);
      return;
    }
    _pending = data;
    _timer ??= Timer(interval - now.difference(last), () {
      _timer = null;
      final pending = _pending;
      _pending = null;
      if (pending != null) {
        _send(pending);
      }
    });
  }

  /// Sends a pending trailing value now.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final pending = _pending;
    _pending = null;
    if (pending != null) {
      _send(pending);
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  void _send(Map<String, dynamic> Function() data) {
    _lastSent = DateTime.now();
    PluginHooks.emit(event, data);
  }
}
