import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

class MultiSelectStatusButton extends ConsumerWidget {
  const MultiSelectStatusButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectCount = ref.watch(multiSelectProvider.select((s) => s.selectedAssets.length));
    final total = ref.watch(timelineServiceProvider).totalAssets;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ElevatedButton.icon(
          onPressed: () => ref.read(multiSelectProvider.notifier).reset(),
          icon: Icon(Icons.close_rounded, color: context.colorScheme.onPrimary),
          label: Text(
            selectCount.toString(),
            style: context.textTheme.titleMedium?.copyWith(height: 2.5, color: context.colorScheme.onPrimary),
          ),
        ),
        if (selectCount < total) ...[
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: () => unawaited(ref.read(multiSelectProvider.notifier).selectAll()),
            icon: const Icon(Icons.select_all_rounded),
            label: const Text('Select all'),
          ),
        ],
      ],
    );
  }
}
