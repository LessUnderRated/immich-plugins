import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/repositories/private_vault.repository.dart';
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
    _lifecycle = AppLifecycleListener(onHide: _lock);
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
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Private'),
        actions: [if (unlocked) IconButton(tooltip: 'Lock', icon: const Icon(Icons.lock_outline), onPressed: _lock)],
      ),
      body: unlocked ? const _PrivateGrid() : _LockedView(busy: _authenticating, message: _message, onUnlock: _unlock),
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
                'Nothing here yet. Select photos in Photos, or open one, and choose "Private" to move it here.',
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
