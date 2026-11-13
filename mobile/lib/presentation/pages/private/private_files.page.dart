import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_json.dart';
import 'package:immich_mobile/infrastructure/repositories/private_files.repository.dart';
import 'package:immich_mobile/presentation/pages/private/private_gallery.page.dart';
import 'package:immich_mobile/presentation/widgets/library/library_plugins.widget.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/private_vault.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:native_video_player/native_video_player.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<void> sharePrivateFiles(List<PrivateFile> files) async {
  final directory = Directory(p.join((await getTemporaryDirectory()).path, 'private_share'));
  if (directory.existsSync()) {
    await directory.delete(recursive: true);
  }
  await directory.create(recursive: true);
  final shared = <XFile>[];
  for (final file in files) {
    final copy = await File(file.file).copy(p.join(directory.path, file.name));
    shared.add(XFile(copy.path, mimeType: file.mime, name: file.name));
  }
  await Share.shareXFiles(shared);
}

Future<int> unhidePrivateFiles(WidgetRef ref, List<PrivateFile> files) async {
  final restored = await ref.read(privateFilesRepositoryProvider).unhide(files);
  unawaited(Future<void>.delayed(const Duration(seconds: 1), () => ref.read(backgroundSyncProvider).syncLocal()));
  return restored;
}

Future<bool> confirmDeletePrivate(BuildContext context, int count) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $count item${count == 1 ? '' : 's'} permanently?'),
        content: const Text('Private items are not in any trash, so this cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    ) ==
    true;

class PrivateFilesView extends ConsumerStatefulWidget {
  final VoidCallback onLock;
  final int legacyCount;

  const PrivateFilesView({super.key, required this.onLock, required this.legacyCount});

  @override
  ConsumerState<PrivateFilesView> createState() => _PrivateFilesViewState();
}

class _PrivateFilesViewState extends ConsumerState<PrivateFilesView> {
  static const _page = LibraryPages.privateGallery;

  final Set<String> _selected = {};

  /// Runs selection action [id] on [files] through hook `action.privateGallery.<id>`.
  void _selectionAction(String id, List<PrivateFile> files, Future<void> Function() original) => libraryTap(
    context,
    _page,
    id,
    original,
    args: () => {
      'files': [for (final file in files) LibraryJson.privateFile(file)],
    },
  );

  void _toggle(PrivateFile file) =>
      setState(() => _selected.contains(file.file) ? _selected.remove(file.file) : _selected.add(file.file));

  List<PrivateFile> _selection(List<PrivateFile> files) =>
      files.where((file) => _selected.contains(file.file)).toList();

  Future<void> _unhide(List<PrivateFile> files) async {
    final messenger = ScaffoldMessenger.of(context);
    final restored = await unhidePrivateFiles(ref, files);
    setState(_selected.clear);
    messenger.showSnackBar(SnackBar(content: Text('Moved $restored back to the gallery')));
  }

  Future<void> _delete(List<PrivateFile> files) async {
    if (!await confirmDeletePrivate(context, files.length)) {
      return;
    }
    await ref.read(privateFilesRepositoryProvider).delete(files);
    setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    final files = ref.watch(privateFilesProvider).valueOrNull ?? const <PrivateFile>[];
    final selecting = _selected.isNotEmpty;
    final selection = _selection(files);

    return Scaffold(
      appBar: AppBar(
        centerTitle: !selecting,
        leading: selecting
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => libraryTap(context, _page, 'close', () => setState(_selected.clear)),
              )
            : null,
        title: Text(selecting ? '${_selected.length} selected' : 'Private'),
        actions: selecting
            ? LibraryPluginHooks.arrange(LibrarySlots.privateGallerySelectionAppBarActions, [
                (
                  id: 'selectAll',
                  item: IconButton(
                    tooltip: 'Select all',
                    icon: const Icon(Icons.select_all),
                    onPressed: () => libraryTap(
                      context,
                      _page,
                      'selectAll',
                      () => setState(() => _selected.addAll(files.map((file) => file.file))),
                    ),
                  ),
                ),
              ])
            : LibraryPluginHooks.arrange(LibrarySlots.appBarActions(_page), [
                if (widget.legacyCount > 0) privateOlderItemsItem(context, widget.legacyCount),
                privateLockItem(context, widget.onLock),
                privateAppMenuItem(),
              ]),
      ),
      bottomNavigationBar: selecting
          ? BottomAppBar(
              height: 64,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: LibraryPluginHooks.arrange(LibrarySlots.privateGallerySelectionActions, [
                  (
                    id: 'share',
                    item: TextButton.icon(
                      icon: const Icon(Icons.share_outlined),
                      label: const Text('Share'),
                      onPressed: () => _selectionAction('share', selection, () => sharePrivateFiles(selection)),
                    ),
                  ),
                  (
                    id: 'unhide',
                    item: TextButton.icon(
                      icon: const Icon(Icons.lock_open_outlined),
                      label: const Text('Unhide'),
                      onPressed: () => _selectionAction('unhide', selection, () => _unhide(selection)),
                    ),
                  ),
                  (
                    id: 'delete',
                    item: TextButton.icon(
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete'),
                      onPressed: () => _selectionAction('delete', selection, () => _delete(selection)),
                    ),
                  ),
                ]),
              ),
            )
          : null,
      body: files.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Select photos in Photos and tap "Private". They are hidden from every app, including other galleries.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : LibraryQueryBuilder<PrivateFile>(
              hook: LibraryHooks.privateFilesQuery,
              items: files,
              id: (file) => file.file,
              toJson: LibraryJson.privateFile,
              builder: (context, files) => GridView.builder(
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                ),
                itemCount: files.length,
                itemBuilder: (context, index) {
                  final file = files[index];
                  final selected = _selected.contains(file.file);
                  return GestureDetector(
                    onLongPress: () => _toggle(file),
                    onTap: () => selecting
                        ? _toggle(file)
                        : libraryTap(
                            context,
                            _page,
                            'open',
                            () => context.pushRoute(PrivateFileViewerRoute(files: files, initialIndex: index)),
                            args: () => {'file': LibraryJson.privateFile(file)},
                          ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        PrivateThumbnail(file: file),
                        if (file.isVideo)
                          const Align(
                            alignment: Alignment.bottomRight,
                            child: Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(Icons.play_circle_fill, color: Colors.white, size: 20),
                            ),
                          ),
                        if (selected) ...[
                          ColoredBox(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25)),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }
}

class PrivateThumbnail extends StatelessWidget {
  final PrivateFile file;

  const PrivateThumbnail({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    final thumb = file.thumb;
    if (thumb != null && File(thumb).existsSync()) {
      return Image.file(File(thumb), fit: BoxFit.cover, gaplessPlayback: true);
    }
    if (file.isVideo) {
      return const ColoredBox(color: Colors.black26);
    }
    return Image.file(
      File(file.file),
      fit: BoxFit.cover,
      cacheWidth: 320,
      errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
    );
  }
}

@RoutePage()
class PrivateFileViewerPage extends ConsumerStatefulWidget {
  final List<PrivateFile> files;
  final int initialIndex;

  const PrivateFileViewerPage({super.key, required this.files, required this.initialIndex});

  @override
  ConsumerState<PrivateFileViewerPage> createState() => _PrivateFileViewerPageState();
}

class _PrivateFileViewerPageState extends ConsumerState<PrivateFileViewerPage> {
  static const _page = LibraryPages.privateFileViewer;

  void _action(String id, Future<void> Function() original) =>
      libraryTap(context, _page, id, original, args: () => {'file': LibraryJson.privateFile(_current)});

  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _showControls = true;

  PrivateFile get _current => widget.files[_index];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _unhide() async {
    final messenger = ScaffoldMessenger.of(context);
    await unhidePrivateFiles(ref, [_current]);
    messenger.showSnackBar(const SnackBar(content: Text('Moved back to the gallery')));
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _delete() async {
    if (!await confirmDeletePrivate(context, 1)) {
      return;
    }
    await ref.read(privateFilesRepositoryProvider).delete([_current]);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
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
              actions: LibraryPluginHooks.arrange(LibrarySlots.appBarActions(_page), [
                (
                  id: 'share',
                  item: IconButton(
                    tooltip: 'Share',
                    icon: const Icon(Icons.share_outlined),
                    onPressed: () => _action('share', () => sharePrivateFiles([_current])),
                  ),
                ),
                (
                  id: 'unhide',
                  item: IconButton(
                    tooltip: 'Unhide',
                    icon: const Icon(Icons.lock_open),
                    onPressed: () => _action('unhide', _unhide),
                  ),
                ),
                (
                  id: 'delete',
                  item: IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _action('delete', _delete),
                  ),
                ),
              ]),
            )
          : null,
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.files.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) {
          final file = widget.files[index];
          return GestureDetector(
            onTap: () => setState(() => _showControls = !_showControls),
            child: file.isVideo
                ? _PrivateFileVideo(key: ValueKey(file.file), path: file.file, active: index == _index)
                : InteractiveViewer(
                    maxScale: 6,
                    child: Center(child: Image.file(File(file.file), fit: BoxFit.contain)),
                  ),
          );
        },
      ),
    );
  }
}

class _PrivateFileVideo extends StatefulWidget {
  final String path;
  final bool active;

  const _PrivateFileVideo({super.key, required this.path, required this.active});

  @override
  State<_PrivateFileVideo> createState() => _PrivateFileVideoState();
}

class _PrivateFileVideoState extends State<_PrivateFileVideo> {
  NativeVideoPlayerController? _controller;
  bool _playing = false;

  @override
  void didUpdateWidget(covariant _PrivateFileVideo oldWidget) {
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
        SizedBox.expand(child: NativeVideoPlayerView(onViewReady: _onReady)),
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
