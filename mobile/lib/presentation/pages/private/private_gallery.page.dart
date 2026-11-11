import 'dart:async';

import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/private_vault.repository.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/move_to_private.action.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/base_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/presentation/pages/private/private_files.page.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:local_auth/local_auth.dart';

@RoutePage()
class PrivateGalleryPage extends ConsumerStatefulWidget {
  const PrivateGalleryPage({super.key});

  @override
  ConsumerState<PrivateGalleryPage> createState() => _PrivateGalleryPageState();
}

class _PrivateGalleryPageState extends ConsumerState<PrivateGalleryPage> {
  late final AppLifecycleListener _lifecycle;
  bool _authenticating = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: _lock, onResume: () => ref.invalidate(privateAccessProvider));
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _lock() {
    if (mounted) {
      ref.read(privateUnlockedProvider.notifier).state = false;
    }
  }

  Future<void> _unlock() async {
    if (_authenticating || ref.read(privateUnlockedProvider)) {
      return;
    }
    setState(() {
      _authenticating = true;
      _message = null;
    });
    try {
      final auth = LocalAuthentication();
      if (!await auth.isDeviceSupported()) {
        setState(() => _message = 'Set a screen lock on this phone to protect the private gallery.');
        return;
      }
      final ok = await auth.authenticate(
        localizedReason: 'Unlock your private gallery',
        options: const AuthenticationOptions(stickyAuth: true),
      );
      if (ok && mounted) {
        ref.read(privateUnlockedProvider.notifier).state = true;
        ref.invalidate(privateItemsProvider);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Unable to unlock: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _authenticating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = ref.watch(privateUnlockedProvider);
    if (unlocked) {
      final access = ref.watch(privateAccessProvider).valueOrNull ?? false;
      final legacyCount = ref.watch(privateItemsProvider).valueOrNull?.length ?? 0;
      if (access) {
        return _MigratingPrivateFiles(onLock: _lock, legacyCount: legacyCount);
      }
      return _PrivateTimeline(onLock: _lock);
    }
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: const Text('Private')),
      body: _LockedView(busy: _authenticating, message: _message, onUnlock: _unlock),
    );
  }
}

class _MigratingPrivateFiles extends ConsumerStatefulWidget {
  final VoidCallback onLock;
  final int legacyCount;

  const _MigratingPrivateFiles({required this.onLock, required this.legacyCount});

  @override
  ConsumerState<_MigratingPrivateFiles> createState() => _MigratingPrivateFilesState();
}

class _MigratingPrivateFilesState extends ConsumerState<_MigratingPrivateFiles> {
  @override
  void initState() {
    super.initState();
    unawaited(_migrate());
  }

  Future<void> _migrate() async {
    final ids = ref.read(privateIdsProvider);
    if (ids.isEmpty) {
      return;
    }
    final db = ref.read(driftProvider);
    final rows = await (db.localAssetEntity.select()..where((row) => row.id.isIn(ids))).get();
    if (rows.isEmpty) {
      return;
    }
    await ref.read(privateFilesRepositoryProvider).hide([for (final row in rows) row.toDto()]);
    await ref.read(backgroundSyncProvider).syncLocal();
  }

  @override
  Widget build(BuildContext context) => PrivateFilesView(onLock: widget.onLock, legacyCount: widget.legacyCount);
}

class _PrivateTimeline extends ConsumerWidget {
  final VoidCallback onLock;

  const _PrivateTimeline({required this.onLock});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(privateIdsProvider);
    final legacyCount = ref.watch(privateItemsProvider).valueOrNull?.length ?? 0;
    return ProviderScope(
      key: ValueKey(Object.hashAllUnordered(ids)),
      overrides: [
        timelineServiceProvider.overrideWith((ref) {
          final timelineService = ref.watch(timelineFactoryProvider).privateAlbum(ids);
          ref.onDispose(timelineService.dispose);
          return timelineService;
        }),
      ],
      child: Timeline(
        topSliverWidget: const SliverToBoxAdapter(child: _FullHidingBanner()),
        topSliverWidgetHeight: 96,
        appBar: SliverAppBar(
          floating: true,
          snap: true,
          centerTitle: true,
          title: const Text('Private'),
          actions: [
            if (legacyCount > 0)
              TextButton(
                onPressed: () => context.pushRoute(const PrivateLegacyRoute()),
                child: Text('Older items ($legacyCount)'),
              ),
            IconButton(tooltip: 'Lock', icon: const Icon(Icons.lock_outline), onPressed: onLock),
          ],
        ),
        groupBy: GroupAssetsBy.none,
        bottomSheet: const _PrivateBottomSheet(),
      ),
    );
  }
}

class _PrivateBottomSheet extends StatelessWidget {
  const _PrivateBottomSheet();

  @override
  Widget build(BuildContext context) {
    return const BaseBottomSheet(
      initialChildSize: 0.18,
      minChildSize: 0.18,
      maxChildSize: 0.18,
      shouldCloseOnMinExtent: false,
      resizeOnScroll: false,
      actions: <ActionColumnButton>[
        .new(action: ShareAction(source: .timeline)),
        .new(action: MoveToPrivateAction(source: .timeline)),
        .new(action: DeleteAction(source: .timeline)),
      ],
    );
  }
}

@RoutePage()
class PrivateLegacyPage extends StatelessWidget {
  const PrivateLegacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Older private items')),
      body: const _PrivateGrid(),
    );
  }
}

class _LockedView extends StatelessWidget {
  final bool busy;
  final String? message;
  final VoidCallback onUnlock;

  const _LockedView({required this.busy, required this.message, required this.onUnlock});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_rounded, size: 56),
            const SizedBox(height: 16),
            const Text('Your private photos are locked', textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.fingerprint),
              label: const Text('Unlock'),
              onPressed: busy ? null : onUnlock,
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivateGrid extends ConsumerWidget {
  const _PrivateGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(privateItemsProvider);
    return items.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('$error')),
      data: (items) {
        if (items.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Items moved here by older versions of the app appear here. Open one to move it back to the gallery.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(2),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) => _PrivateTile(
            item: items[index],
            onTap: () => context.pushRoute(PrivateViewerRoute(items: items, initialIndex: index)),
          ),
        );
      },
    );
  }
}

class _PrivateTile extends ConsumerWidget {
  final PrivateItem item;
  final VoidCallback onTap;

  const _PrivateTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.read(privateVaultRepositoryProvider);
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<String>(
            future: repository.path(item.thumb ?? item.file),
            builder: (context, snapshot) {
              final path = snapshot.data;
              if (path == null || (item.thumb == null && item.isVideo)) {
                return const ColoredBox(color: Colors.black26);
              }
              return Image.file(
                File(path),
                fit: BoxFit.cover,
                cacheWidth: 320,
                errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
              );
            },
          ),
          if (item.isVideo)
            const Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.play_circle_fill, color: Colors.white, size: 20),
              ),
            ),
        ],
      ),
    );
  }
}

class _FullHidingBanner extends ConsumerWidget {
  const _FullHidingBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.visibility_off_outlined),
          title: const Text('Hide from other apps too'),
          subtitle: const Text(
            'Private photos are only hidden in this app. Allow "All files access" to hide them everywhere.',
          ),
          trailing: FilledButton.tonal(
            onPressed: () => ref.read(privateFilesRepositoryProvider).requestAccess(),
            child: const Text('Allow'),
          ),
        ),
      ),
    );
  }
}
