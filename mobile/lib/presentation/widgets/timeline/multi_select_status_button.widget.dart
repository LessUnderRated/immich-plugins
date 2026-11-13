import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_mobile/presentation/actions/action_ids.dart';
import 'package:immich_mobile/presentation/actions/action_slots.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

class MultiSelectStatusButton extends ConsumerWidget {
  const MultiSelectStatusButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectCount = ref.watch(multiSelectProvider.select((s) => s.selectedAssets.length));
    final timeline = ref.watch(timelineServiceProvider);
    final total = timeline.totalAssets;
    final children = arrangeButtons(
      ref,
      ActionSlots.selectionStatus,
      [
        BuiltinSlotItem(
          id: TimelineItemIds.clearSelection,
          child: ElevatedButton.icon(
            onPressed: () => ref.read(multiSelectProvider.notifier).reset(),
            icon: Icon(Icons.close_rounded, color: context.colorScheme.onPrimary),
            label: Text(
              selectCount.toString(),
              style: context.textTheme.titleMedium?.copyWith(height: 2.5, color: context.colorScheme.onPrimary),
            ),
          ),
        ),
        if (selectCount < total)
          BuiltinSlotItem(
            id: TimelineItemIds.selectAll,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: FilledButton.tonalIcon(
                onPressed: () => unawaited(ref.read(multiSelectProvider.notifier).selectAll(timeline)),
                icon: const Icon(Icons.select_all_rounded),
                label: const Text('Select all'),
              ),
            ),
          ),
      ],
      context: {'selectionCount': selectCount, 'total': total, 'origin': timeline.origin.name},
    );
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}
