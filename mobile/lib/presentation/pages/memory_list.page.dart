import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/asyncvalue_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_events.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/viewer_ids.dart';
import 'package:immich_mobile/presentation/actions/action_slots.dart';
import 'package:immich_mobile/presentation/pages/memory.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_slots.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_title.widget.dart';
import 'package:immich_mobile/presentation/widgets/sliver_app_bar/app_menu.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/routing/router.dart';

@RoutePage()
class MemoryListPage extends ConsumerStatefulWidget {
  const MemoryListPage({super.key});

  @override
  ConsumerState<MemoryListPage> createState() => _MemoryListPageState();
}

class _MemoryListPageState extends ConsumerState<MemoryListPage> {
  bool _onlyFavorites = false;

  @override
  Widget build(BuildContext context) {
    final memories = ref.watch(allMemoriesProvider(_onlyFavorites));

    return LayoutBuilder(
      builder: (context, constraints) {
        return Scaffold(
          appBar: AppBar(
            title: Text(context.t.memories),
            // Built-in ids: ViewerBuiltinIds.memoryListActions; plugin buttons of the slot join them.
            actions: arrangeButtons(ref, ViewerSlotIds.memoryListActions, [
              BuiltinSlotItem(
                id: 'favorites',
                child: IconButton(
                  icon: Icon(_onlyFavorites ? Icons.favorite : Icons.favorite_outline),
                  onPressed: () {
                    setState(() => _onlyFavorites = !_onlyFavorites);
                  },
                ),
              ),
              if (arrangeMenuItems(ref, ViewerSlotIds.memoryListMenu, const []) case final entries
                  when entries.isNotEmpty)
                AppBarOverflowMenu(children: entries),
            ]),
          ),
          body: SafeArea(
            child: memories.widgetWhen(
              onData: (memories) {
                if (memories.isEmpty) {
                  return ViewerSlotContentView(
                    slot: ViewerSlotIds.memoryListEmpty,
                    extra: {'onlyFavorites': _onlyFavorites},
                  );
                }
                return GridView.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: constraints.maxWidth > 600 ? 4 : 2,
                    childAspectRatio: 0.5625,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                  ),
                  padding: const EdgeInsets.all(16),
                  itemCount: memories.length,
                  itemBuilder: (context, index) => ViewerSlotDecoration(
                    key: ValueKey(memories[index].id),
                    slot: ViewerSlotIds.memoryListTile,
                    slotContext: () => {'memory': memoryJson(memories[index])},
                    child: GestureDetector(
                      onTap: () {
                        MemoryPage.setMemory(ref, memories[index]);
                        unawaited(context.pushRoute(MemoryRoute(memories: memories, memoryIndex: index)));
                      },
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: const BorderRadius.all(Radius.circular(10)),
                            child: ColorFiltered(
                              colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.2), BlendMode.darken),
                              child: AbsorbPointer(
                                child: Thumbnail.remote(
                                  remoteId: memories[index].assets[0].id,
                                  thumbhash: memories[index].assets[0].thumbHash ?? "",
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 16,
                            left: 16,
                            right: 16,
                            child: MemoryTitle(
                              memory: memories[index],
                              style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white, fontSize: 15),
                              preferDate: true,
                            ),
                          ),
                          if (memories[index].isSaved)
                            const Positioned(
                              top: 16,
                              right: 16,
                              child: Icon(Icons.favorite, color: Colors.white, size: 24),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
