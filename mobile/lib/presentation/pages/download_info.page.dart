import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/pages/common/download_task_tile.dart';
import 'package:immich_mobile/presentation/widgets/library/library_plugins.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/download.provider.dart';

@RoutePage()
class DownloadInfoPage extends ConsumerWidget {
  const DownloadInfoPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(downloadStateProvider.select((state) => state.taskProgress)).entries.toList();

    const page = LibraryPages.downloadInfo;

    void onCancelDownload(String id) {
      unawaited(ref.read(downloadStateProvider.notifier).cancelDownload(id));
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.t.download), actions: const []),
      body: ListView.builder(
        physics: const ClampingScrollPhysics(),
        shrinkWrap: true,
        itemCount: tasks.length,
        itemBuilder: (context, index) {
          final task = tasks[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: DownloadTaskTile(
              progress: task.value.progress,
              fileName: task.value.fileName,
              status: task.value.status,
              onCancelDownload: () => libraryTap(
                context,
                page,
                'cancel',
                () => onCancelDownload(task.key),
                args: () => {'taskId': task.key, 'fileName': task.value.fileName, 'progress': task.value.progress},
              ),
            ),
          );
        },
      ),
      persistentFooterButtons: LibraryPluginHooks.arrange(LibrarySlots.footer(page), [
        (
          id: 'clearAll',
          item: OutlinedButton(
            onPressed: () => libraryTap(
              context,
              page,
              'clearAll',
              () {
                tasks.map((e) => e.key).forEach(onCancelDownload);
              },
              args: () => {
                'taskIds': [for (final task in tasks) task.key],
              },
            ),
            style: OutlinedButton.styleFrom(side: BorderSide(color: context.colorScheme.primary)),
            child: Text(
              context.t.clear_all,
              style: context.textTheme.labelLarge?.copyWith(color: context.colorScheme.primary),
            ),
          ),
        ),
      ]),
    );
  }
}
