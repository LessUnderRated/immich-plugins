import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_mobile/infrastructure/repositories/device_trash.repository.dart';
import 'package:immich_mobile/presentation/actions/action_hooks.dart';
import 'package:immich_mobile/presentation/actions/action_ids.dart';
import 'package:immich_mobile/presentation/actions/action_slots.dart';
import 'package:immich_mobile/presentation/widgets/sliver_app_bar/app_menu.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_slots.widget.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/infrastructure/device_trash.provider.dart';
import 'package:immich_mobile/providers/timeline/timeline_plugins.provider.dart';

@RoutePage()
class DeviceTrashPage extends ConsumerStatefulWidget {
  const DeviceTrashPage({super.key});

  @override
  ConsumerState<DeviceTrashPage> createState() => _DeviceTrashPageState();
}

class _DeviceTrashPageState extends ConsumerState<DeviceTrashPage> {
  final Map<String, Future<String?>> _thumbs = {};
  final Set<String> _selected = {};
  List<DeviceTrashedItem>? _items;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final items = await ref.read(deviceTrashRepositoryProvider).list();
    if (mounted) {
      setState(() {
        _items = items;
        _selected.removeWhere((id) => !_items!.any((item) => item.id == id));
      });
    }
  }

  Future<String?> _thumb(DeviceTrashedItem item) =>
      _thumbs.putIfAbsent(item.id, () => ref.read(deviceTrashRepositoryProvider).thumbnail(item));

  List<DeviceTrashedItem> get _selection => (_items ?? const []).where((item) => _selected.contains(item.id)).toList();

  Future<void> _run(String actionId, String method, List<DeviceTrashedItem> items, String done) async {
    if (items.isEmpty) {
      return;
    }
    await ActionHooks.run(
      actionId,
      () => _runMethod(method, items, done),
      () => ActionHookCall(
        actionId: actionId,
        args: {
          'items': [for (final item in items) item.toJson()],
        },
      ),
    );
  }

  Future<void> _runMethod(String method, List<DeviceTrashedItem> items, String done) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repository = ref.read(deviceTrashRepositoryProvider);
      final ok = method == 'restoreTrashed' ? await repository.restore(items) : await repository.deleteForever(items);
      if (ok) {
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

    const page = TimelinePages.deviceTrash;
    final bridge = ref.watch(timelinePluginBridgeProvider);
    Map<String, dynamic> slotContext() => {
      'page': page,
      'total': items?.length ?? 0,
      'selectionCount': _selected.length,
      'items': [for (final item in _selection) item.toJson()],
    };
    final header = timelineSlotContent(bridge, [TimelineSlots.header(page)], slotContext);
    final footer = timelineSlotContent(bridge, [TimelineSlots.footer(page)], slotContext);
    final empty = items != null && items.isEmpty
        ? timelineSlotContent(bridge, [TimelineSlots.empty(page)], slotContext)
        : null;

    Widget restore(String label) => TextButton.icon(
      icon: const Icon(Icons.restore),
      label: Text(label),
      onPressed: _busy ? null : () => _run(ActionIds.deviceTrashRestore, 'restoreTrashed', _selection, 'Restored'),
    );
    Widget deleteForever(String label) => TextButton.icon(
      icon: const Icon(Icons.delete_forever_outlined),
      label: Text(label),
      onPressed: _busy ? null : () => _run(ActionIds.deviceTrashDelete, 'deleteTrashed', _selection, 'Deleted'),
    );

    final Widget body = items == null
        ? const Center(child: CircularProgressIndicator())
        : items.isEmpty
        ? empty ??
              Center(
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
          );

    return Scaffold(
      appBar: AppBar(
        title: Text(selecting ? '${_selected.length} selected' : 'Trash'),
        actions: [
          PageAppBarActions(
            page: page,
            slotContext: {'selectionCount': _selected.length},
            actions: [
              if (items != null && items.isNotEmpty)
                BuiltinSlotItem(
                  id: TimelineItemIds.selectAll,
                  child: TextButton(
                    onPressed: () => setState(
                      () => _selected.length == items.length
                          ? _selected.clear()
                          : _selected.addAll(items.map((item) => item.id)),
                    ),
                    child: Text(_selected.length == items.length ? 'Select none' : 'Select all'),
                  ),
                ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: selecting
          ? BottomAppBar(
              height: 64,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: arrangeButtons(ref, ActionSlots.deviceTrashSelection, [
                  BuiltinSlotItem(id: TimelineItemIds.restore, relabel: restore, child: restore('Restore')),
                  BuiltinSlotItem(
                    id: TimelineItemIds.deleteForever,
                    relabel: deleteForever,
                    child: deleteForever('Delete forever'),
                  ),
                ], context: slotContext()),
              ),
            )
          : null,
      body: header == null && footer == null
          ? body
          : Column(
              children: [
                ?header,
                Expanded(child: body),
                ?footer,
              ],
            ),
    );
  }
}
