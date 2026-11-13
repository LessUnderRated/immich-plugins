import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/image_pipeline.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_bridge.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_host_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/providers/viewer_censor.provider.dart';

/// Plugin API of the **viewer** area: viewer, video sessions and overlays, image pipeline (`viewer.*`, `video.*`,
/// `image.load`, `image.invalidate` host functions; `image.*`, `video.*` and `viewer.gesture` hooks run through
/// `PluginHooks`).
void registerViewerPluginApi(PluginKernel kernel, Ref ref) {
  for (final MapEntry(key: name, value: function) in ViewerHostApi(ref).functions.entries) {
    kernel.registerHost(name, function, area: 'viewer');
  }

  // The viewer censor shield is a generic toggle: plugins read and set it like their own.
  kernel.toggles.define(
    PluginToggleDefinition(
      key: viewerShieldToggle,
      defaultValue: true,
      title: 'Censor while viewing',
      read: () => ref.read(viewerCensorEnabledProvider),
      write: (value) => ref.read(viewerCensorEnabledProvider.notifier).set(value),
    ),
  );

  ViewerPlugins.bind(_KernelViewerBridge(kernel));
  ImagePipeline.subjectJson = (subject) async {
    final id = subject.localId ?? subject.remoteId;
    final asset = id == null ? null : await kernel.findAsset(id);
    if (asset != null) {
      return kernel.assetJson(asset);
    }
    return {
      'id': id,
      if (subject.localId != null) 'localId': subject.localId,
      if (subject.remoteId != null) 'remoteId': subject.remoteId,
      if (subject.checksum != null) 'checksum': subject.checksum,
      'type': subject.type.name.toUpperCase(),
    };
  };

  // Cached images depend on the plugins handling the image hooks: drop them when that set changes.
  final hooks = kernel.hookChanges.listen((changed) {
    if (changed.any((id) => id.startsWith('image.'))) {
      ImagePipeline.invalidate();
    }
    ViewerPlugins.notifyChanged();
  });
  ref.onDispose(() {
    unawaited(hooks.cancel());
    ViewerPlugins.bind(null);
    ImagePipeline.subjectJson = null;
  });
}

class _KernelViewerBridge implements ViewerPluginBridge {
  final PluginKernel _kernel;

  const _KernelViewerBridge(this._kernel);

  @override
  Future<Map<String, dynamic>> assetJson(BaseAsset asset) => _kernel.assetJson(asset);

  @override
  String hookSignature(String hookId) => _kernel.hookSignature(hookId);
}
