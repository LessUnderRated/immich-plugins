import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';

/// A photo or video in the Android system trash (MediaStore `IS_TRASHED`).
class DeviceTrashedItem {
  final String id;
  final String name;
  final bool isVideo;
  final DateTime? expires;
  final DateTime? takenAt;

  const DeviceTrashedItem({
    required this.id,
    required this.name,
    required this.isVideo,
    required this.expires,
    this.takenAt,
  });

  factory DeviceTrashedItem.fromMap(Map<dynamic, dynamic> map) => DeviceTrashedItem(
    id: '${map['id']}',
    name: map['name'] as String? ?? '',
    isVideo: map['video'] == true,
    expires: map['expires'] == null ? null : DateTime.fromMillisecondsSinceEpoch((map['expires'] as num).toInt()),
    takenAt: map['takenAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch((map['takenAt'] as num).toInt()),
  );

  Map<String, Object> toArgs() => {'id': id, 'video': isVideo};

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': isVideo ? 'VIDEO' : 'IMAGE',
    'expiresAt': expires?.toUtc().toIso8601String(),
    'takenAt': takenAt?.toUtc().toIso8601String(),
  };
}

/// The device's system trash (Android 11+): list, thumbnails, restore and delete forever.
///
/// Restoring and deleting show the system confirmation; both return whether the user granted it.
class DeviceTrashRepository {
  static const _channel = MethodChannel('immich/device_media');

  const DeviceTrashRepository();

  /// Every trashed item, soonest to expire last. Plugins can filter or sort the list through `trash.query`.
  Future<List<DeviceTrashedItem>> list() async {
    final rows = await _channel.invokeListMethod<Map>('listTrashed') ?? const <Map>[];
    final items = rows.map(DeviceTrashedItem.fromMap).toList();
    return PluginHooks.filterList<DeviceTrashedItem>(
      DataHooks.trashQuery,
      () => {'source': 'device'},
      items,
      () => PluginListCodec<DeviceTrashedItem>(id: (item) => item.id, toJson: (item) => item.toJson()),
    );
  }

  /// A JPEG thumbnail path for a trashed item, or null when the system cannot make one.
  Future<String?> thumbnail(DeviceTrashedItem item) =>
      _channel.invokeMethod<String>('trashThumbnail', {'id': item.id, 'video': item.isVideo});

  /// Puts items back into the gallery; runs as `asset.restore` with `source: "device"`.
  Future<bool> restore(List<DeviceTrashedItem> items) => _run(
    DataHooks.assetRestore,
    DataEvents.assetRestored,
    'restoreTrashed',
    items,
    const {'source': 'device'},
  );

  /// Deletes items for good; runs as `asset.delete` with `source: "device"` and `permanent: true`.
  Future<bool> deleteForever(List<DeviceTrashedItem> items) => _run(
    DataHooks.assetDelete,
    DataEvents.assetDeleted,
    'deleteTrashed',
    items,
    const {'source': 'device', 'permanent': true},
  );

  Future<bool> _run(
    String hook,
    String event,
    String method,
    List<DeviceTrashedItem> items,
    Map<String, dynamic> extra,
  ) => PluginHooks.run<bool>(
    hook,
    () => {
      'ids': [for (final item in items) item.id],
      'items': [for (final item in items) item.toJson()],
      ...extra,
    },
    () => _invoke(method, items),
    withArgs: (args) {
      final ids = PluginArgs.strings(args['ids']).toSet();
      return _invoke(method, items.where((item) => ids.contains(item.id)).toList());
    },
    encode: (granted) => granted,
    decode: (json) => PluginArgs.boolean(json) ?? false,
    event: event,
  );

  Future<bool> _invoke(String method, List<DeviceTrashedItem> items) async {
    if (items.isEmpty) {
      return true;
    }
    return await _channel.invokeMethod<bool>(method, {
          'items': [for (final item in items) item.toArgs()],
        }) ??
        false;
  }
}
