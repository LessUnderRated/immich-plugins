import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/repositories/private_vault.repository.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:native_video_player/native_video_player.dart';

@RoutePage()
class PrivateViewerPage extends ConsumerStatefulWidget {
  final List<PrivateItem> items;
  final int initialIndex;

  const PrivateViewerPage({super.key, required this.items, required this.initialIndex});

  @override
  ConsumerState<PrivateViewerPage> createState() => _PrivateViewerPageState();
}

class _PrivateViewerPageState extends ConsumerState<PrivateViewerPage> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _showControls = true;

  PrivateItem get _current => widget.items[_index];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final repository = ref.read(privateVaultRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    await repository.restore(_current);
    ref.invalidate(privateItemsProvider);
    await ref.read(backgroundSyncProvider).syncLocal();
    messenger.showSnackBar(const SnackBar(content: Text('Moved back to the gallery')));
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: const Text('This item will be removed from the private gallery and cannot be recovered.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await ref.read(privateVaultRepositoryProvider).delete(_current);
    ref.invalidate(privateItemsProvider);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.read(privateVaultRepositoryProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _showControls
          ? AppBar(
              backgroundColor: Colors.transparent,
              foregroundColor: Colors.white,
              elevation: 0,
              flexibleSpace: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xA6000000), Colors.transparent],
                  ),
                ),
              ),
              title: Text(_current.name, style: const TextStyle(fontSize: 14)),
              actions: [
                IconButton(tooltip: 'Move back to gallery', icon: const Icon(Icons.lock_open), onPressed: _restore),
                IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
              ],
            )
          : null,
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.items.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) {
          final item = widget.items[index];
          return GestureDetector(
            onTap: () => setState(() => _showControls = !_showControls),
            child: FutureBuilder<String>(
              future: repository.path(item.file),
              builder: (context, snapshot) {
                final path = snapshot.data;
                if (path == null) {
                  return const SizedBox.shrink();
                }
                if (item.isVideo) {
                  return _PrivateVideo(key: ValueKey(item.id), path: path, active: index == _index);
                }
                return InteractiveViewer(
                  maxScale: 6,
                  child: Center(child: Image.file(File(path), fit: BoxFit.contain)),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _PrivateVideo extends StatefulWidget {
  final String path;
  final bool active;

  const _PrivateVideo({super.key, required this.path, required this.active});

  @override
  State<_PrivateVideo> createState() => _PrivateVideoState();
}

class _PrivateVideoState extends State<_PrivateVideo> {
  NativeVideoPlayerController? _controller;
  bool _playing = false;

  @override
  void didUpdateWidget(covariant _PrivateVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active && _playing) {
      unawaited(_toggle());
    }
  }

  Future<void> _onReady(NativeVideoPlayerController controller) async {
    _controller = controller;
    await controller.loadVideoSource(await VideoSource.init(path: widget.path, type: VideoSourceType.file));
    if (widget.active) {
      await controller.play();
      if (mounted) {
        setState(() => _playing = true);
      }
    }
  }

  Future<void> _toggle() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    _playing ? await controller.pause() : await controller.play();
    if (mounted) {
      setState(() => _playing = !_playing);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: SizedBox.expand(child: NativeVideoPlayerView(onViewReady: _onReady)),
        ),
        IconButton(
          iconSize: 44,
          color: Colors.white70,
          icon: Icon(_playing ? Icons.pause_circle_outline : Icons.play_circle_outline),
          onPressed: _toggle,
        ),
      ],
    );
  }
}
