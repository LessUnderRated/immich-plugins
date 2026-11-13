import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/action_ids.dart';
import 'package:immich_mobile/presentation/actions/asset_debug.action.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/restore.action.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/selection_actions.widget.dart';

class TrashBottomBar extends StatelessWidget {
  const TrashBottomBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        color: context.themeData.canvasColor,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SafeArea(
          top: false,
          child: SelectionActions(
            sheet: SelectionSheets.trash,
            actions: const <ActionColumnButton>[
              .new(action: AssetDebugAction(source: .timeline)),
              .new(action: DeleteAction(source: .timeline)),
              .new(action: RestoreAction(source: .timeline)),
            ],
            builder: (_, actions) => Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: actions),
          ),
        ),
      ),
    );
  }
}
