import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/image_pipeline.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/video_sessions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_bridge.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_host_api.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart';
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
  // `videoPlayer.overlay` slot items of kind `view`: attached natively into every video player they match, like
  // `video.nativeOverlay.attach`; detached when the plugin drops them.
  final videoOverlays = _VideoOverlaySlots(kernel);
  VideoSessions.instance.addListener(videoOverlays.sync);
  kernel.addListener(videoOverlays.sync);
  ref.onDispose(() {
    VideoSessions.instance.removeListener(videoOverlays.sync);
    kernel.removeListener(videoOverlays.sync);
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

class _VideoOverlaySlots {
  final PluginKernel _kernel;

  /// Attached items per session id: `<plugin>/<id>`.
  final Map<String, Set<String>> _attached = {};

  _VideoOverlaySlots(this._kernel);

  void sync() {
    final sessions = VideoSessions.instance.sessions;
    _attached.removeWhere((id, _) => !sessions.any((session) => session.id == id));
    if (!_kernel.hasSlot(ViewerSlotIds.videoOverlay) && _attached.isEmpty) {
      return;
    }
    for (final session in sessions) {
      if (session.viewId == null) {
        continue;
      }
      final context = {
        ...PluginKernel.assetContext([session.asset]),
        'sessionId': session.id,
        'surface': session.surface,
        if (session.frameRect != null) 'frameRect': VideoSession.rectJson(session.frameRect!),
      };
      final wanted = {
        for (final item in _kernel.slot(ViewerSlotIds.videoOverlay, context: context))
          if (item.kind == PluginSlotKind.view && item.view != null) '${item.plugin}/${item.id}': item,
      };
      final attached = _attached.putIfAbsent(session.id, () => <String>{});
      for (final key in attached.difference(wanted.keys.toSet()).toList()) {
        attached.remove(key);
        final slash = key.indexOf('/');
        unawaited(
          PluginVideoChannel.detachOverlay(
            session,
            plugin: key.substring(0, slash),
            id: key.substring(slash + 1),
          ).catchError((_) {}),
        );
      }
      for (final MapEntry(:key, value: item) in wanted.entries) {
        if (attached.add(key)) {
          unawaited(_attach(session, item).catchError((_) => attached.remove(key)));
        }
      }
    }
  }

  Future<void> _attach(VideoSession session, SlotContribution item) async {
    await VideoSessions.instance.ensureNative(session);
    await PluginVideoChannel.attachOverlay(
      session,
      plugin: item.plugin,
      view: item.view!,
      id: item.id,
      params: {...item.params, 'sessionId': session.id},
      interactive: item.interactive,
    );
  }
}
