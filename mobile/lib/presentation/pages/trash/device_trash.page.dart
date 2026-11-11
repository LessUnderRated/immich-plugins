import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';

const _channel = MethodChannel('immich/device_media');

class _TrashedItem {
  final String id;
  final String name;
  final bool isVideo;
  final DateTime? expires;

  const _TrashedItem({required this.id, required this.name, required this.isVideo, required this.expires});

  factory _TrashedItem.fromMap(Map<dynamic, dynamic> map) => _TrashedItem(
    id: '${map['id']}',
    name: map['name'] as String? ?? '',
    isVideo: map['video'] == true,
    expires: map['expires'] == null ? null : DateTime.fromMillisecondsSinceEpoch((map['expires'] as num).toInt()),
  );

  Map<String, Object> toArgs() => {'id': id, 'video': isVideo};
}

@RoutePage()
class DeviceTrashPage extends ConsumerStatefulWidget {
  const DeviceTrashPage({super.key});

  @override
  ConsumerState<DeviceTrashPage> createState() => _DeviceTrashPageState();
}

class _DeviceTrashPageState extends ConsumerState<DeviceTrashPage> {
  final Map<String, Future<String?>> _thumbs = {};
  final Set<String> _selected = {};
  List<_TrashedItem>? _items;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await _channel.invokeListMethod<Map>('listTrashed') ?? const [];
    if (mounted) {
      setState(() {
        _items = rows.map(_TrashedItem.fromMap).toList();
        _selected.removeWhere((id) => !_items!.any((item) => item.id == id));
      });
    }
  }

  Future<String?> _thumb(_TrashedItem item) => _thumbs.putIfAbsent(
    item.id,
    () => _channel.invokeMethod<String>('trashThumbnail', {'id': item.id, 'video': item.isVideo}),
  );

  List<_TrashedItem> get _selection => (_items ?? const []).where((item) => _selected.contains(item.id)).toList();

  Future<void> _run(String method, List<_TrashedItem> items, String done) async {
    if (items.isEmpty) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final ok = await _channel.invokeMethod<bool>(method, {'items': items.map((item) => item.toArgs()).toList()});
      if (ok == true) {
        messenger.showSnackBar(SnackBar(content: Text(done)));
        _selected.clear();
        await ref.read(backgroundSyncProvider).syncLocal();
      }
    } finally {
      await _load();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _daysLeft(DateTime? expires) {
    if (expires == null) {
      return '';
    }
    final days = expires.difference(DateTime.now()).inDays;
    return days <= 0 ? 'Today' : '${days}d';
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final selecting = _selected.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(selecting ? '${_selected.length} selected' : 'Trash'),
        actions: [
          if (items != null && items.isNotEmpty)
            TextButton(
              onPressed: () => setState(
                () => _selected.length == items.length
                    ? _selected.clear()
                    : _selected.addAll(items.map((item) => item.id)),
              ),
              child: Text(_selected.length == items.length ? 'Select none' : 'Select all'),
            ),
        ],
      ),
      bottomNavigationBar: selecting
          ? BottomAppBar(
              height: 64,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.restore),
                    label: const Text('Restore'),
                    onPressed: _busy ? null : () => _run('restoreTrashed', _selection, 'Restored'),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_forever_outlined),
                    label: const Text('Delete forever'),
                    onPressed: _busy ? null : () => _run('deleteTrashed', _selection, 'Deleted'),
                  ),
                ],
              ),
            )
          : null,
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  Platform.isAndroid
                      ? 'The trash is empty. Items deleted from this app stay here for 30 days.'
                      : 'Trash is only available on Android.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: GridView.builder(
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final selected = _selected.contains(item.id);
                  return GestureDetector(
                    onTap: () => setState(() => selected ? _selected.remove(item.id) : _selected.add(item.id)),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        FutureBuilder<String?>(
                          future: _thumb(item),
                          builder: (context, snapshot) {
                            final path = snapshot.data;
                            return path == null
                                ? ColoredBox(color: scheme.surfaceContainerHighest)
                                : Image.file(File(path), fit: BoxFit.cover, gaplessPlayback: true);
                          },
                        ),
                        Positioned(
                          left: 4,
                          bottom: 4,
                          child: Text(
                            _daysLeft(item.expires),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                            ),
                          ),
                        ),
                        if (item.isVideo)
                          const Positioned(
                            right: 4,
                            bottom: 4,
                            child: Icon(Icons.play_circle_fill, color: Colors.white, size: 18),
                          ),
                        if (selected) ...[
                          ColoredBox(color: scheme.primary.withValues(alpha: 0.25)),
                          Positioned(top: 4, right: 4, child: Icon(Icons.check_circle, color: scheme.primary)),
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
