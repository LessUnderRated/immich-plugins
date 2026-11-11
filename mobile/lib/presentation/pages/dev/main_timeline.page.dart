import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/device_library_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';

@RoutePage()
class MainTimelinePage extends StatelessWidget {
  const MainTimelinePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Timeline(
      appBar: SliverAppBar(floating: true, snap: true, centerTitle: true, title: Text(context.t.photos)),
      bottomSheet: const DeviceLibraryBottomSheet(),
    );
  }
}
