import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/gallery_view.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/device_album.repository.dart';
import 'package:immich_mobile/providers/app_album.provider.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('GalleryView');

class GalleryViewSelections extends Notifier<Map<String, GalleryViewSelection>> {
  @override
  Map<String, GalleryViewSelection> build() {
    final raw = Store.tryGet(StoreKey.galleryViews);
    if (raw == null || raw.isEmpty) {
      return const {};
    }
    try {
      final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return {
        for (final entry in json.entries)
          if (entry.value is Map)
            entry.key: GalleryViewSelection.fromJson(Map<String, dynamic>.from(entry.value as Map)),
      };
    } catch (error) {
      _log.warning('Ignoring unreadable gallery view settings', error);
      return const {};
    }
  }

  Future<void> set(String scope, GalleryViewSelection? selection) async {
    final next = {...state};
    selection == null ? next.remove(scope) : next[scope] = selection;
    state = next;
    await Store.put(
      StoreKey.galleryViews,
      jsonEncode({for (final entry in next.entries) entry.key: entry.value.toJson()}),
    );
  }
}

final galleryViewSelectionsProvider = NotifierProvider<GalleryViewSelections, Map<String, GalleryViewSelection>>(
  GalleryViewSelections.new,
);

final galleryViewSpecProvider = FutureProvider.family<GalleryViewSpec?, String>((ref, scope) async {
  final selection = ref.watch(galleryViewSelectionsProvider.select((selections) => selections[scope]));
  if (selection == null) {
    return null;
  }

  final engine = ref.watch(deviceWorkflowEngineProvider);
  final appAlbums = await ref.watch(appAlbumsProvider.future);
  final albums = [
    for (final album in appAlbums) (id: album.id, name: album.name),
    for (final album in await const DeviceAlbumRepository().albums()) (id: album.id, name: album.name),
  ];
  final isMain = scope == mainGalleryViewScope;
  try {
    final response = await engine.callPluginMethod(selection.pluginName, selection.methodName, {
      'trigger': 'GalleryView',
      'type': galleryViewType,
      'config': selection.config,
      'workflow': {'id': 'gallery-view', 'authToken': '', 'stepId': scope},
      'data': {
        'scope': isMain ? 'main' : 'album',
        'albumId': isMain ? null : scope,
        'albums': [
          for (final album in albums) {'id': album.id, 'name': album.name},
        ],
      },
    });
    final view = response?['view'];
    if (view is! Map) {
      return null;
    }

    final spec = GalleryViewSpec.fromJson(Map<String, dynamic>.from(view));
    if (!isMain) {
      return spec;
    }

    return spec.withExcludedAssets({
      for (final album in appAlbums)
        if (spec.excludeAlbumIds.contains(album.id)) ...album.assetIds,
    });
  } catch (error, stack) {
    _log.severe('Gallery view ${selection.key} failed', error, stack);
    return null;
  }
});
