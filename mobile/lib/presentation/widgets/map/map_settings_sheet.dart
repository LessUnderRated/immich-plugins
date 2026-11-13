import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/time_range.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/presentation/widgets/library/library_plugins.widget.dart';
import 'package:immich_mobile/presentation/widgets/map/map.state.dart';
import 'package:immich_mobile/widgets/map/map_settings/map_custom_time_range.dart';
import 'package:immich_mobile/widgets/map/map_settings/map_settings_list_tile.dart';
import 'package:immich_mobile/widgets/map/map_settings/map_settings_time_dropdown.dart';

class MapSettingsSheet extends ConsumerStatefulWidget {
  const MapSettingsSheet({super.key});

  @override
  ConsumerState<MapSettingsSheet> createState() => _MapSettingsSheetState();
}

class _MapSettingsSheetState extends ConsumerState<MapSettingsSheet> {
  late bool useCustomRange;

  @override
  void initState() {
    super.initState();
    final mapState = ref.read(mapStateProvider);
    final timeRange = mapState.timeRange;
    useCustomRange = timeRange.from != null || timeRange.to != null;
  }

  @override
  Widget build(BuildContext context) {
    final mapState = ref.watch(mapStateProvider);

    // Every setting runs through hook `action.map.<setting id>` with `{ "value" }`
    void setting(String id, Object? value, void Function() original) =>
        libraryTap(context, LibraryPages.map, id, original, args: () => {'value': value});

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: useCustomRange ? 0.7 : 0.6,
      builder: (ctx, scrollController) => SingleChildScrollView(
        controller: scrollController,
        child: Card(
          elevation: 0.0,
          shadowColor: Colors.transparent,
          color: Colors.transparent,
          margin: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              ...LibraryPluginHooks.arrange(LibrarySlots.mapSettings, [
                (
                  id: 'systemTheme',
                  item: MapSettingsListTile(
                    title: context.t.theme_setting_system_theme_switch,
                    selected: mapState.themeMode == .system,
                    onChanged: (isSystem) => setting(
                      'systemTheme',
                      isSystem,
                      () => ref.read(mapStateProvider.notifier).switchTheme(isSystem ? .system : .light),
                    ),
                  ),
                ),
                if (mapState.themeMode != .system)
                  (
                    id: 'darkMode',
                    item: MapSettingsListTile(
                      title: context.t.map_settings_dark_mode,
                      selected: mapState.themeMode == .dark,
                      onChanged: (isDark) => setting(
                        'darkMode',
                        isDark,
                        () => ref.read(mapStateProvider.notifier).switchTheme(isDark ? .dark : .light),
                      ),
                    ),
                  ),
                (id: 'divider', item: const Divider(height: 30, thickness: 1)),
                (
                  id: 'favoritesOnly',
                  item: MapSettingsListTile(
                    title: context.t.map_settings_only_show_favorites,
                    selected: mapState.onlyFavorites,
                    onChanged: (favoriteOnly) => setting(
                      'favoritesOnly',
                      favoriteOnly,
                      () => ref.read(mapStateProvider.notifier).switchFavoriteOnly(favoriteOnly),
                    ),
                  ),
                ),
                (
                  id: 'includeArchived',
                  item: MapSettingsListTile(
                    title: context.t.map_settings_include_show_archived,
                    selected: mapState.includeArchived,
                    onChanged: (includeArchive) => setting(
                      'includeArchived',
                      includeArchive,
                      () => ref.read(mapStateProvider.notifier).switchIncludeArchived(includeArchive),
                    ),
                  ),
                ),
                (
                  id: 'withPartners',
                  item: MapSettingsListTile(
                    title: context.t.map_settings_include_show_partners,
                    selected: mapState.withPartners,
                    onChanged: (withPartners) => setting(
                      'withPartners',
                      withPartners,
                      () => ref.read(mapStateProvider.notifier).switchWithPartners(withPartners),
                    ),
                  ),
                ),
                (
                  id: 'timeRange',
                  item: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (useCustomRange) ...[
                        MapTimeRange(
                          timeRange: mapState.timeRange,
                          onChanged: (range) => setting('timeRange', {
                            'from': range.from?.toUtc().toIso8601String(),
                            'to': range.to?.toUtc().toIso8601String(),
                          }, () => ref.read(mapStateProvider.notifier).setCustomTimeRange(range)),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () => setting(
                              'timeRange',
                              'relative',
                              () => setState(() {
                                useCustomRange = false;
                                ref.read(mapStateProvider.notifier).setRelativeTime(0);
                                ref.read(mapStateProvider.notifier).setCustomTimeRange(const TimeRange());
                              }),
                            ),
                            child: Text(context.t.remove_custom_date_range),
                          ),
                        ),
                      ] else ...[
                        MapTimeDropDown(
                          relativeTime: mapState.relativeDays,
                          onTimeChange: (time) => setting(
                            'timeRange',
                            time,
                            () => ref.read(mapStateProvider.notifier).setRelativeTime(time),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () => setting(
                              'timeRange',
                              'custom',
                              () => setState(() {
                                useCustomRange = true;
                                ref.read(mapStateProvider.notifier).setRelativeTime(0);
                                ref.read(mapStateProvider.notifier).setCustomTimeRange(const TimeRange());
                              }),
                            ),
                            child: Text(context.t.use_custom_date_range),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
