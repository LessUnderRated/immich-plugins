import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/repositories/downloads_rule.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';

final downloadsOrganizerProvider = Provider<DownloadsOrganizer>((ref) {
  ref.keepAlive();
  return DownloadsOrganizer(ref.watch(driftProvider));
});
