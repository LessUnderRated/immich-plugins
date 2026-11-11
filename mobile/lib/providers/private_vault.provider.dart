import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/repositories/private_vault.repository.dart';

final privateVaultRepositoryProvider = Provider((ref) => const PrivateVaultRepository());

final privateUnlockedProvider = StateProvider<bool>((ref) => false);

final privateItemsProvider = FutureProvider<List<PrivateItem>>(
  (ref) => ref.watch(privateVaultRepositoryProvider).list(),
);
