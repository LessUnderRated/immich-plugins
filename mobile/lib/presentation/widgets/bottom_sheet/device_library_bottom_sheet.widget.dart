import 'package:flutter/material.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/base_bottom_sheet.widget.dart';

class DeviceLibraryBottomSheet extends StatelessWidget {
  const DeviceLibraryBottomSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return const BaseBottomSheet(
      initialChildSize: 0.18,
      minChildSize: 0.18,
      maxChildSize: 0.18,
      shouldCloseOnMinExtent: false,
      resizeOnScroll: false,
      actions: <ActionColumnButton>[
        .new(action: ShareAction(source: .timeline)),
        .new(action: DeleteAction(source: .timeline)),
      ],
    );
  }
}
