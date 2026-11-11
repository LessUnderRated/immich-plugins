import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';

const offlineUserId = '00000000-0000-4000-8000-000000000001';

final offlineUser = UserDto(
  id: offlineUserId,
  email: 'gallery@localhost',
  name: 'Gallery',
  profileChangedAt: DateTime.utc(2000),
  memoryEnabled: false,
);

Future<void> ensureOfflineUser() async {
  final store = StoreService.I;
  if (store.tryGet(StoreKey.currentUser) == null) {
    await store.put(StoreKey.currentUser, offlineUser);
  }
}
