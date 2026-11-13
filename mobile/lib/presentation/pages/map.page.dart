import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/presentation/widgets/library/library_plugins.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map_settings_sheet.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

@RoutePage()
class MapPage extends StatelessWidget {
  final LatLng? initialLocation;

  const MapPage({super.key, this.initialLocation});

  Future<void> onSettingsPressed(BuildContext context) {
    return showModalBottomSheet(
      elevation: 0.0,
      showDragHandle: true,
      isScrollControlled: true,
      context: context,
      builder: (_) => const MapSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          MapView(initialLocation: initialLocation),
          Positioned(
            left: 20,
            top: 70,
            child: IconButton.filled(
              color: Colors.white,
              onPressed: () => libraryTap(context, LibraryPages.map, 'back', () => ContextHelper(context).pop()),
              icon: const Icon(Icons.arrow_back_ios_new_rounded),
              style: IconButton.styleFrom(
                padding: const EdgeInsets.all(8),
                backgroundColor: Colors.indigo,
                shadowColor: Colors.black26,
                elevation: 4,
              ),
            ),
          ),
          Positioned(
            right: 20,
            top: 70,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: LibraryPluginHooks.arrange(LibrarySlots.appBarActions(LibraryPages.map), [
                (
                  id: 'settings',
                  item: IconButton.filled(
                    color: Colors.white,
                    onPressed: () =>
                        libraryTap(context, LibraryPages.map, 'settings', () => onSettingsPressed(context)),
                    icon: const Icon(Icons.more_vert_rounded),
                    style: IconButton.styleFrom(
                      padding: const EdgeInsets.all(8),
                      backgroundColor: Colors.indigo,
                      shadowColor: Colors.black26,
                      elevation: 4,
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
