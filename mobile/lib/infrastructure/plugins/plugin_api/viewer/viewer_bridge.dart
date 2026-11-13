import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

/// What the viewer area needs from the plugin kernel besides hooks and events (those go through `PluginHooks`) and
/// slot rules and items (those come from the timeline area's `TimelinePluginBridge`, shared by every bar and menu).
///
/// The kernel binds an implementation at startup (phase B, `viewer_plugin_api.dart`). Unbound, everything here has
/// a working default, so the viewer behaves exactly as without plugins.
abstract interface class ViewerPluginBridge {
  /// AssetV1 JSON for a local or remote asset.
  Future<Map<String, dynamic>> assetJson(BaseAsset asset);

  /// A string that changes whenever the set or the versions of the plugins handling [hookId] change
  /// (e.g. `"censor@1.2.0:instead,upscale@0.3:after"`). Part of the image pipeline cache keys.
  String hookSignature(String hookId);
}

/// Static access to the bound [ViewerPluginBridge], with defaults when none is bound.
abstract final class ViewerPlugins {
  static ViewerPluginBridge? _bridge;

  /// Bumped whenever the binding changes.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static void bind(ViewerPluginBridge? bridge) {
    _bridge = bridge;
    changes.value++;
  }

  /// Tells listeners that plugins changed (the kernel calls this after a plugin refresh).
  static void notifyChanged() => changes.value++;

  static bool get isBound => _bridge != null;

  static Future<Map<String, dynamic>> assetJson(BaseAsset asset) async {
    final bridge = _bridge;
    if (bridge == null) {
      return basicAssetJson(asset);
    }
    try {
      return await bridge.assetJson(asset);
    } catch (_) {
      return basicAssetJson(asset);
    }
  }

  static String hookSignature(String hookId) => _bridge?.hookSignature(hookId) ?? '';

  /// The AssetV1 fields that can be built synchronously from the asset itself. The kernel's [assetJson] adds the
  /// rest (paths, EXIF, tags, ...).
  static Map<String, dynamic> basicAssetJson(BaseAsset asset) => {
    'id': asset.id,
    'localId': asset.localId,
    'remoteId': asset.remoteId,
    'type': assetTypeName(asset.type),
    'originalFileName': asset.name,
    'checksum': asset.checksum,
    'isFavorite': asset.isFavorite,
    'isEdited': asset.isEdited,
    'isLocal': asset.hasLocal,
    'isRemote': asset.hasRemote,
    'storage': asset.storage.name,
    'playbackStyle': asset.playbackStyle.name,
    'width': asset.width,
    'height': asset.height,
    'durationMs': asset.durationMs,
    'fileCreatedAt': asset.createdAt.toUtc().toIso8601String(),
    'fileModifiedAt': asset.updatedAt.toUtc().toIso8601String(),
    if (asset is RemoteAsset) ...{'ownerId': asset.ownerId, 'stackId': asset.stackId, 'thumbHash': asset.thumbHash},
  };

  static String assetTypeName(AssetType type) => switch (type) {
    AssetType.image => 'IMAGE',
    AssetType.video => 'VIDEO',
    AssetType.audio => 'AUDIO',
    AssetType.other => 'OTHER',
  };
}
