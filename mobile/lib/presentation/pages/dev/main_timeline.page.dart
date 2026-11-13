import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/gallery_view.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_mobile/presentation/plugins/plugin_ui.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/device_library_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/gallery_view/gallery_view_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/sliver_app_bar/app_menu.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_plugin_bridge.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';

@RoutePage()
class MainTimelinePage extends StatelessWidget {
  const MainTimelinePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Timeline(
      page: TimelinePages.mainTimeline,
      appBar: SliverAppBar(
        floating: true,
        snap: true,
        centerTitle: true,
        title: Text(context.t.photos),
        actions: const [
          // Legacy `contributes.buttons` with slot `main.appBar`
          PluginSlotButtons(slot: 'main.appBar'),
          PageAppBarActions(
            page: TimelinePages.mainTimeline,
            actions: [
              BuiltinSlotItem(
                id: TimelineItemIds.galleryView,
                child: GalleryViewButton(scope: mainGalleryViewScope),
              ),
            ],
          ),
          AppBarMenuActions(),
        ],
      ),
      groupBy: GroupAssetsBy.none,
      bottomSheet: const DeviceLibraryBottomSheet(),
    );
  }
}
