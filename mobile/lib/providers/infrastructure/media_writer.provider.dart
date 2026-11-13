import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/media_writer.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';

/// Writes photos and videos into the gallery (editor save-as-copy / replace, `media.*` host functions).
final mediaWriterProvider = Provider<MediaWriter>(
  (ref) => MediaWriter(
    ref.watch(deviceEditRepositoryProvider),
    ref.watch(driftProvider).localAssetRepository.get,
    onLibraryChanged: () => ref.read(backgroundSyncProvider).syncLocal(),
  ),
);
