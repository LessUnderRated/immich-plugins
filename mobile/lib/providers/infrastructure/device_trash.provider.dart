import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/repositories/device_trash.repository.dart';

final deviceTrashRepositoryProvider = Provider<DeviceTrashRepository>((ref) => const DeviceTrashRepository());
