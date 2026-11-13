import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_slots.dart';

class FilterBottomSheetScaffold extends StatelessWidget {
  const FilterBottomSheetScaffold({
    super.key,
    required this.child,
    this.onSearch,
    required this.onClear,
    required this.title,
    this.expanded,
    this.sheet,
  });

  /// The `search.filters` id of this sheet, for plugin content of `search.filterSheet`.
  final String? sheet;
  final bool? expanded;
  final String title;
  final Widget child;
  final Function()? onSearch;
  final Function() onClear;

  @override
  Widget build(BuildContext context) {
    Widget buildChildWidget() {
      if (expanded != null && expanded == true) {
        return Expanded(child: child);
      }
      return child;
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(title, style: context.textTheme.headlineSmall),
          ),
          buildChildWidget(),
          ViewerSlotContentView(slot: LibrarySlots.searchFilterSheet, extra: {'sheet': ?sheet}),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: () {
                    onClear();
                    context.pop();
                  },
                  child: Text(context.t.clear),
                ),
                if (onSearch != null) const SizedBox(width: 8),
                if (onSearch != null)
                  ElevatedButton(
                    key: const Key('search_filter_apply'),
                    onPressed: () {
                      onSearch!();
                      context.pop();
                    },
                    child: Text(context.t.search_filter_apply),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
