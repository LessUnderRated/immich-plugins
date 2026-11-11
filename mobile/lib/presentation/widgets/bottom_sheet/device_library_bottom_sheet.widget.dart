import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/delete.action.dart';
import 'package:immich_mobile/presentation/actions/device_album.actions.dart';
import 'package:immich_mobile/presentation/actions/move_to_private.action.dart';
import 'package:immich_mobile/presentation/actions/share.action.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/base_bottom_sheet.widget.dart';

class DeviceLibraryBottomSheet extends StatelessWidget {
  final LocalAlbum? album;

  const DeviceLibraryBottomSheet({super.key, this.album});

  @override
  Widget build(BuildContext context) {
    final album = this.album;
    return BaseBottomSheet(
      initialChildSize: 0.18,
      minChildSize: 0.18,
      maxChildSize: 0.18,
      shouldCloseOnMinExtent: false,
      resizeOnScroll: false,
      actions: <ActionColumnButton>[
        const .new(action: ShareAction(source: .timeline)),
        .new(
          action: AddToDeviceAlbumAction(source: .timeline, currentAlbumId: album?.id),
        ),
        .new(
          action: MoveToDeviceAlbumAction(source: .timeline, currentAlbumId: album?.id),
        ),
        if (album != null)
          .new(
            action: RemoveFromDeviceAlbumAction(source: .timeline, albumName: album.name),
          ),
        const .new(action: DeviceFavoriteAction(source: .timeline)),
        const .new(action: MoveToPrivateAction(source: .timeline)),
        const .new(action: DeleteAction(source: .timeline)),
      ],
    );
  }
}
