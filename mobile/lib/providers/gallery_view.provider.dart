import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/gallery_view.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';

final galleryViewProvider = NotifierProvider<GalleryViewNotifier, Map<String, GalleryViewOptions>>(
  GalleryViewNotifier.new,
);

final galleryViewOptionsProvider = Provider.family<GalleryViewOptions, String>(
  (ref, scope) => ref.watch(galleryViewProvider.select((views) => views[scope])) ?? const GalleryViewOptions(),
);

class GalleryViewNotifier extends Notifier<Map<String, GalleryViewOptions>> {
  @override
  Map<String, GalleryViewOptions> build() {
    final stored = Store.tryGet(StoreKey.galleryViewOptions);
    if (stored == null) {
      return const {};
    }

    try {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      return {
        for (final MapEntry(:key, :value) in json.entries)
          if (value is Map) key: GalleryViewOptions.fromJson(Map<String, Object?>.from(value)),
      };
    } catch (_) {
      return const {};
    }
  }

  Future<void> update(String scope, GalleryViewOptions options) async {
    state = {
      for (final MapEntry(:key, :value) in state.entries)
        if (key != scope) key: value,
      if (!options.isDefault) scope: options,
    };
    await Store.put(
      StoreKey.galleryViewOptions,
      jsonEncode({for (final MapEntry(:key, :value) in state.entries) key: value.toJson()}),
    );
  }
}
