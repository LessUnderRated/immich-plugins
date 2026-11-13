import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_mobile/presentation/widgets/sliver_app_bar/app_menu.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';

@RoutePage()
class CleanupPreviewPage extends StatelessWidget {
  final List<LocalAsset> assets;

  const CleanupPreviewPage({super.key, required this.assets});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t.cleanup_preview_title(count: assets.length)),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: context.colorScheme.surface,
        actions: const [PageAppBarActions(page: TimelinePages.cleanupPreview)],
      ),
      body: ProviderScope(
        overrides: [
          timelineServiceProvider.overrideWith((ref) {
            final timelineService = ref
                .watch(timelineFactoryProvider)
                .fromAssetsWithBuckets(assets.cast<BaseAsset>(), TimelineOrigin.search);
            ref.onDispose(timelineService.dispose);
            return timelineService;
          }),
        ],
        child: const Timeline(
          page: TimelinePages.cleanupPreview,
          appBar: null,
          bottomSheet: null,
          groupBy: GroupAssetsBy.day,
          readOnly: true,
        ),
      ),
    );
  }
}
